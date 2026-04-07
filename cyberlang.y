/* ================================================================
   cyberlang.y  –  Bison Parser for CyberLang
   ================================================================
   Features:
     1. Full grammar  (all data types, control flow, functions)
     2. Symbol table  (scope-aware, redeclaration / undeclared warnings)
     3. Three-Address Code (TAC) generation
     4. Constant-folding optimisation
     5. Loop / if-chain / switch label stacks
     6. For-loop update deferred via output-capture buffer
     7. do-while, switch/case/default, logical operators
     8. All unique CyberLang functions
   ================================================================ */

%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <stdarg.h>
#include <stdbool.h>

extern int yylex();
extern int line_no;
void yyerror(const char *s);
static FILE *outFile = NULL;

/* ================================================================
   OUTPUT  –  supports deferred (buffered) emission for the
   for-loop update expression so it is printed AFTER the body.
   ================================================================ */

static char emitBuf[16384];
static int  emitBufLen  = 0;
static int  emitDeferred = 0;

/* All TAC output goes through emit(); switch to buffer when capturing. */
static void emit(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    if (emitDeferred) {
        emitBufLen += vsprintf(emitBuf + emitBufLen, fmt, ap);
    } else {
        vfprintf(outFile ? outFile : stdout, fmt, ap);
    }
    va_end(ap);
}

static void startCapture(void) {
    emitDeferred = 1;
    emitBufLen   = 0;
    emitBuf[0]   = '\0';
}

static char* stopCapture(void) {
    emitDeferred = 0;
    return strdup(emitBuf);
}

/* ================================================================
   TEMP AND LABEL GENERATION
   ================================================================ */
static int tempCnt  = 0;
static int labelCnt = 0;

static char* newTemp(void) {
    char buf[16];
    sprintf(buf, "t%d", tempCnt++);
    emit("double %s;\n", buf);
    return strdup(buf);
}

static char* newLabel(void) {
    char buf[16];
    sprintf(buf, "L%d", labelCnt++);
    return strdup(buf);
}

/* ================================================================
   LOOP STACK  -  tracks break / continue targets
   ================================================================ */
#define MAX_DEPTH 100

static char *breakStk[MAX_DEPTH];
static char *contStk [MAX_DEPTH];
static int   loopTop = -1;

static void pushLoop(char *brk, char *cont) {
    if (++loopTop >= MAX_DEPTH) {
        fputs("Internal error: loop stack overflow\n", stderr); exit(1);
    }
    breakStk[loopTop] = brk;
    contStk [loopTop] = cont;
}
static void  popLoop (void) { if (loopTop >= 0) loopTop--; }
static char* curBreak(void) { return loopTop >= 0 ? breakStk[loopTop] : NULL; }
static char* curCont (void) { return loopTop >= 0 ? contStk [loopTop] : NULL; }

/* ================================================================
   AUXILIARY STACK  –  reused for:
     • if-chain false labels
     • while / for / do-while start labels
     • switch per-case "next check" labels
   Nested constructs push/pop correctly because each pops its
   own label before returning.
   ================================================================ */
static char *auxStk[MAX_DEPTH];
static int   auxTop = -1;
static void  auxPush(char *s) { if (++auxTop < MAX_DEPTH) auxStk[auxTop] = s; }
static char* auxPop (void)    { return auxTop >= 0 ? auxStk[auxTop--] : NULL; }
static char* auxPeek(void)    { return auxTop >= 0 ? auxStk[auxTop]   : NULL; }

/* ================================================================
   IF-CHAIN END LABEL STACK
   ================================================================ */
static char *ifEndStk[MAX_DEPTH];
static int   ifEndTop = -1;

/* ================================================================
   SWITCH EXPRESSION STACK
   ================================================================ */
static char *swExprStk[MAX_DEPTH];
static int   swTop = -1;

/* ================================================================
   SYMBOL TABLE  (scope-aware)
   ================================================================ */
#define MAX_SYMS 512

typedef struct { char *name; char *type; int scope; } Sym;
static Sym symTab[MAX_SYMS];
static int symCnt   = 0;
static int curScope = 0;

typedef struct { char *name; char *retType; } FuncSym;
static FuncSym funcTab[MAX_SYMS];
static int funcCnt = 0;

static void funcAdd(const char *name, const char *retType) {
    for (int i = 0; i < funcCnt; i++) {
        if (strcmp(funcTab[i].name, name) == 0) {
            free(funcTab[i].retType);
            funcTab[i].retType = strdup(retType);
            return;
        }
    }
    if (funcCnt < MAX_SYMS) {
        funcTab[funcCnt].name = strdup(name);
        funcTab[funcCnt].retType = strdup(retType);
        funcCnt++;
    }
}

static const char* funcRetType(const char *name) {
    for (int i = 0; i < funcCnt; i++) {
        if (strcmp(funcTab[i].name, name) == 0) {
            return funcTab[i].retType;
        }
    }
    return NULL;
}

static void symAdd(const char *name, const char *type) {
    for (int i = symCnt - 1; i >= 0; i--) {
        if (symTab[i].scope == curScope &&
            strcmp(symTab[i].name, name) == 0) {
            fprintf(stderr,
                "Semantic Warning at line %d: '%s' redeclared "
                "in same scope (ignored)\n", line_no, name);
            return;
        }
    }
    if (symCnt < MAX_SYMS) {
        symTab[symCnt].name  = strdup(name);
        symTab[symCnt].type  = strdup(type);
        symTab[symCnt].scope = curScope;
        symCnt++;
    }
}

static char* symLookup(const char *name) {
    for (int i = symCnt - 1; i >= 0; i--)
        if (strcmp(symTab[i].name, name) == 0)
            return symTab[i].type;
    return NULL;
}

static void symEnterScope(void) { curScope++; }

static void symExitScope(void) {
    /* remove symbols that belong to the current (innermost) scope */
    while (symCnt > 0 && symTab[symCnt-1].scope == curScope) {
        free(symTab[symCnt-1].name);
        free(symTab[symCnt-1].type);
        symCnt--;
    }
    if (curScope > 0) curScope--;
}

/* Semantic check: warn if name not declared */
static void checkUse(const char *name) {
    if (!symLookup(name))
        fprintf(stderr,
            "Semantic Error at line %d: '%s' used before declaration\n",
            line_no, name);
}

/* ================================================================
   CONSTANT FOLDING
   Checks if a TAC operand is a plain integer literal.
   If both operands of + - * / % are literals, fold at compile time.
   ================================================================ */
static int isIntLit(const char *s) {
    if (!s || !*s) return 0;
    const char *p = (*s == '-') ? s + 1 : s;
    if (!*p) return 0;
    for (; *p; p++) if (!isdigit((unsigned char)*p)) return 0;
    return 1;
}

static char* foldBinop(char op, const char *a, const char *b) {
    if (!isIntLit(a) || !isIntLit(b)) return NULL;
    int ia = atoi(a), ib = atoi(b), r;
    switch (op) {
        case '+': r = ia + ib; break;
        case '-': r = ia - ib; break;
        case '*': r = ia * ib; break;
        case '/':
            if (!ib) {
                fputs("Optimization Warning: constant division by zero – not folded\n",
                      stderr);
                return NULL;
            }
            r = ia / ib; break;
        case '%':
            if (!ib) return NULL;
            r = ia % ib; break;
        default:  return NULL;
    }
    char buf[32];
    sprintf(buf, "%d", r);
    return strdup(buf);
}

static int isStringLit(const char *s) {
    return s && s[0] == '"';
}

static int isCharLit(const char *s) {
    return s && s[0] == '\'';
}

static const char* scanfFmtForType(const char *type) {
    if (!type) return "%lf";
    if (strcmp(type, "int") == 0) return "%d";
    if (strcmp(type, "float") == 0) return "%f";
    if (strcmp(type, "double") == 0) return "%lf";
    if (strcmp(type, "long int") == 0) return "%ld";
    if (strcmp(type, "char") == 0) return " %c";
    if (strcmp(type, "long long") == 0) return "%lld";
    if (strcmp(type, "bool") == 0) return "%d";
    return "%lf";
}

%}

/* ================================================================
   BISON VALUE UNION
   ================================================================ */
%union {
    int    intval;
    float  floatval;
    char  *str;
}

/* ================================================================
   TOKEN DECLARATIONS
   ================================================================ */

/* Preprocessor */
%token INJECT MACRO

/* Function */
%token CYBER BOOTUP

/* Data types */
%token BYTE DECI BIGDECI MEGABYTE SYMBOL_TYPE BINARY TIMESTAMP VOID

/* Control flow */
%token IF ELSEIF ELSE FOR WHILE DO CONTINUE BREAK RETURN

/* Switch */
%token SWITCH CASE DEFAULT

/* I/O */
%token DISPLAY CAPTURE

/* Logical operators */
%token AND OR NOT XOR

/* Unique functions */
%token ISPRIME NOW TIMEDIFF FORMAT_TIME PARSE_TIME

/* Operators */
%token ASSIGN ARROW INC DEC
%token PLUS MINUS MULTIPLY DIVIDE MOD
%token GT LT GTE LTE EQ NEQ

/* Delimiters */
%token SEMICOLON COMMA COLON LPAREN RPAREN LBRACE RBRACE

/* Valued tokens */
%token <intval>  NUMBER
%token <floatval> FLOATNUM
%token <str>     IDENTIFIER STRING CHARLIT

/* ================================================================
   NON-TERMINAL TYPES
   ================================================================ */
%type <str> type expr arg_list param_list params assign_expr func_call

/* ================================================================
   OPERATOR PRECEDENCE  (lowest → highest, last = tightest binding)
   ================================================================ */
%left  OR
%left  XOR
%left  AND
%left  EQ NEQ
%left  GT LT GTE LTE
%left  PLUS MINUS
%left  MULTIPLY DIVIDE MOD
%right NOT UMINUS

%%

/* ================================================================
   TOP-LEVEL PROGRAM
   ================================================================ */

program
    : inject_list func_list
      {
          emit("\n/* Temps used: %d, Labels used: %d */\n", tempCnt, labelCnt);
      }
    ;

/* ---- Optional @inject / @macro directives ---- */
inject_list
    : /* empty */
    | inject_list inject_stmt
    ;

inject_stmt
    : INJECT IDENTIFIER SEMICOLON
      { emit("#include <%s>\n", $2); }
    | INJECT STRING SEMICOLON
      { emit("#include %s\n", $2); }
    | MACRO IDENTIFIER expr SEMICOLON
      { emit("#define %s %s\n", $2, $3); }
    ;

/* ================================================================
   FUNCTION DECLARATIONS
   ================================================================ */

func_list
    : func_list func_decl
    | func_decl
    ;

func_decl
    /* cyber funcName(params) => returnType { body } */
    : CYBER IDENTIFIER LPAREN param_list RPAREN ARROW type
      {
                    funcAdd($2, $7);
          emit("\n%s %s(%s) {\n", $7, $2, ($4 && *$4) ? $4 : "void");
          symEnterScope();
      }
      LBRACE stmt_list RBRACE
      {
          emit("}\n");
          symExitScope();
      }

    /* bootup() { body }  –  entry point */
    | BOOTUP LPAREN RPAREN
      {
          emit("\nint main(void) {\n");
          symEnterScope();
      }
      LBRACE stmt_list RBRACE
      {
          emit("return 0;\n}\n");
          symExitScope();
      }
    ;

/* ---- Parameter list ---- */
param_list
    : /* empty */
      { $$ = strdup(""); }
    | params
      { $$ = $1; }
    ;

params
    : type IDENTIFIER
      {
          symAdd($2, $1);
          char buf[128];
          sprintf(buf, "%s %s", $1, $2);
          $$ = strdup(buf);
      }
    | params COMMA type IDENTIFIER
      {
          symAdd($4, $3);
          char buf[512];
          sprintf(buf, "%s, %s %s", $1, $3, $4);
          $$ = strdup(buf);
      }
    ;

/* ================================================================
   TYPE NAMES
   ================================================================ */
type
    : BYTE        { $$ = strdup("int");       }
    | DECI        { $$ = strdup("float");     }
    | BIGDECI     { $$ = strdup("double");    }
    | MEGABYTE    { $$ = strdup("long int");  }
    | SYMBOL_TYPE { $$ = strdup("char");      }
    | BINARY      { $$ = strdup("bool");      }
    | TIMESTAMP   { $$ = strdup("long long"); }
    | VOID        { $$ = strdup("void");      }
    ;

/* ================================================================
   STATEMENT LIST
   ================================================================ */
stmt_list
    : stmt_list statement
    | statement
    ;

statement
    : declaration
    | assign_expr SEMICOLON          /* e.g.  x << 5; */
    | expr        SEMICOLON          /* e.g.  isPrime(7);  myFunc(); */
    | display_stmt
    | capture_stmt
    | if_stmt
    | while_stmt
    | for_stmt
    | do_while_stmt
    | switch_stmt
    | return_stmt
    | break_stmt
    | continue_stmt
    | SEMICOLON                      /* empty statement */
    ;

/* ================================================================
   VARIABLE DECLARATIONS
   ================================================================ */
declaration
    /* byte x;  */
    : type IDENTIFIER SEMICOLON
      {
          symAdd($2, $1);
          emit("%s %s;\n", $1, $2);
      }

    /* byte x << 5;  */
    | type IDENTIFIER ASSIGN expr SEMICOLON
      {
          symAdd($2, $1);
          emit("%s %s;\n", $1, $2);
          emit("%s = %s;\n", $2, $4);
      }
    ;

/* ================================================================
   ASSIGNMENT EXPRESSION  (no semicolon; used in stmt and for-loop)
   ================================================================ */
assign_expr
    /* x << expr */
    : IDENTIFIER ASSIGN expr
      {
          checkUse($1);
          emit("%s = %s;\n", $1, $3);
          $$ = $1;
      }
    /* x++ */
    | IDENTIFIER INC
      {
          checkUse($1);
          emit("%s = %s + 1;\n", $1, $1);
          $$ = $1;
      }
    /* x-- */
    | IDENTIFIER DEC
      {
          checkUse($1);
          emit("%s = %s - 1;\n", $1, $1);
          $$ = $1;
      }
    ;

/* ================================================================
   I/O STATEMENTS
   ================================================================ */

/* display("format", args...)  /  display(expr) */
display_stmt
    : DISPLAY LPAREN expr RPAREN SEMICOLON
      {
          if (isStringLit($3)) emit("printf(\"%%s\\n\", %s);\n", $3);
          else if (isCharLit($3)) emit("printf(\"%%c\\n\", %s);\n", $3);
          else emit("printf(\"%%g\\n\", (double)(%s));\n", $3);
      }
    | DISPLAY LPAREN expr COMMA arg_list RPAREN SEMICOLON
      { emit("printf(%s, %s);\n", $3, $5); }
    ;

/* capture("format", &x, ...)  /  capture(x) */
capture_stmt
    : CAPTURE LPAREN expr COMMA arg_list RPAREN SEMICOLON
      { emit("scanf(%s, %s);\n", $3, $5); }
    | CAPTURE LPAREN IDENTIFIER RPAREN SEMICOLON
            {
                    checkUse($3);
                    emit("scanf(\"%s\", &%s);\n", scanfFmtForType(symLookup($3)), $3);
            }
    ;

/* comma-separated expression list (for display/capture/calls) */
arg_list
    : expr
      { $$ = $1; }
    | arg_list COMMA expr
      {
          char buf[1024];
          sprintf(buf, "%s, %s", $1, $3);
          $$ = strdup(buf);
      }
    ;

/* ================================================================
   IF / YELLOW(ELSEIF) / RED(ELSE)
   ================================================================
   TAC pattern:
       ifFalse <cond> goto L_false
       <true body>
       goto L_end
   L_false:
       [elseif checks … ]
       [else body]
   L_end:
   ================================================================ */
if_stmt
    : IF LPAREN expr RPAREN
      {
          /* mid-rule: after condition – generate false-jump */
          char *falseL = newLabel();
          char *endL   = newLabel();
          ifEndStk[++ifEndTop] = endL;
          auxPush(falseL);
          emit("if (!(%s)) goto %s;\n", $3, falseL);
      }
      LBRACE stmt_list RBRACE
      {
          /* mid-rule: after true body – jump over else chain */
          emit("goto %s;\n",   ifEndStk[ifEndTop]);
          /* FIX: label followed by null statement ";" so a declaration
             can legally appear next in C                              */
          emit("%s: ;\n",      auxPeek());
      }
      elseif_chain else_part
      {
          /* final: emit end label, clean stacks */
          auxPop();
          emit("%s: ;\n", ifEndStk[ifEndTop--]);
      }
    ;

elseif_chain
    : /* empty */
    | elseif_chain ELSEIF LPAREN expr RPAREN
      {
          /* mid-rule: another condition test */
          char *nextL = newLabel();
          emit("if (!(%s)) goto %s;\n", $4, nextL);
          auxPush(nextL);
      }
      LBRACE stmt_list RBRACE
      {
          emit("goto %s;\n", ifEndStk[ifEndTop]);
          emit("%s: ;\n",    auxPop());    /* FIX: null statement after label */
      }
    ;

else_part
    : /* empty */
    | ELSE LBRACE stmt_list RBRACE
    ;

/* ================================================================
   WHILE LOOP  (repeat)
   ================================================================
   TAC pattern:
   L_start:
       ifFalse <cond> goto L_end
       <body>
       goto L_start
   L_end:
   ================================================================ */
while_stmt
    : WHILE LPAREN
      {
          /* mid-rule A: before condition – emit loop start */
          char *start = newLabel();
          char *end   = newLabel();
          pushLoop(end, start);
          auxPush(start);
          emit("%s: ;\n", start);    /* FIX: null statement after label */
      }
      expr RPAREN
      {
          /* mid-rule B: after condition – conditional exit */
          emit("if (!(%s)) goto %s;\n", $4, curBreak());
      }
      LBRACE stmt_list RBRACE
      {
          emit("goto %s;\n",   auxPop());
          emit("%s: ;\n",     curBreak());  /* FIX: null statement after label */
          popLoop();
      }
    ;

/* ================================================================
   FOR LOOP  (round)
   ================================================================
   Grammar:  round( init ; cond ; update ) { body }
   TAC:
       <init>
   L_start:
       ifFalse <cond> goto L_end
       <body>
   L_update:
       <update>          ← deferred via output-capture buffer
       goto L_start
   L_end:
   ================================================================ */
for_stmt
    : FOR LPAREN
        assign_expr SEMICOLON             /* $3 = init  (TAC already emitted) */
        {
            /* mid-rule A ($5): set up labels after init */
            char *start = newLabel();
            char *end   = newLabel();
            char *upd   = newLabel();
            pushLoop(end, upd);
            auxPush(start);
            emit("%s: ;\n", start);    /* FIX: null statement after label */
        }
        expr SEMICOLON                    /* $6 = condition */
        {
            /* mid-rule B ($8): condition check; start capturing update */
            emit("if (!(%s)) goto %s;\n", $6, curBreak());
            startCapture();               /* redirect emit() to buffer */
        }
        assign_expr                       /* $9 = update  → buffered */
        {
            /* mid-rule C ($10): end capture, store deferred TAC */
            $<str>$ = stopCapture();
        }
        RPAREN LBRACE stmt_list RBRACE    /* $11 $12 $13 $14 */
        {
            emit("%s: ;\n",  curCont());   /* FIX: null statement after label */
            emit("%s",       $<str>10);   /* deferred update expression TAC */
            emit("goto %s;\n", auxPop()); /* back to L_start */
            emit("%s: ;\n",  curBreak()); /* FIX: null statement after label */
            popLoop();
        }
    ;

/* ================================================================
   DO-WHILE LOOP  (execute … repeat)
   ================================================================
   TAC:
   L_start:
       <body>
       ifTrue <cond> goto L_start
   L_end:
   ================================================================ */
do_while_stmt
    : DO
      {
          /* mid-rule ($2): emit start label */
          char *start = newLabel();
          char *end   = newLabel();
          pushLoop(end, start);
          auxPush(start);
          emit("%s: ;\n", start);    /* FIX: null statement after label */
      }
      LBRACE stmt_list RBRACE WHILE LPAREN expr RPAREN SEMICOLON
      {
          emit("if (%s) goto %s;\n", $8, auxPop());
          emit("%s: ;\n", curBreak());  /* FIX: null statement after label */
          popLoop();
      }
    ;

/* ================================================================
   SWITCH / CASE / DEFAULT  (matrix / node / default)
   ================================================================
   Sequential-check TAC (correct, no fall-through):
       <switch_tmp> = <expr>
       <t> = switch_tmp == val1
       ifFalse <t> goto L_next1
       <case1 body>
       goto L_end
   L_next1:
       <t> = switch_tmp == val2
       ifFalse <t> goto L_default
       <case2 body>
       goto L_end
   L_default:
       <default body>
   L_end:
   ================================================================ */
switch_stmt
    : SWITCH LPAREN expr RPAREN
      {
          /* Evaluate switch expression into a temp */
          char *t   = newTemp();
          char *end = newLabel();
          emit("%s = %s;\n", t, $3);
          swExprStk[++swTop] = t;
          pushLoop(end, end);     /* hack(break) → L_end */
      }
      LBRACE case_list default_opt RBRACE
      {
          emit("%s: ;\n", curBreak());  /* FIX: null statement after label */
          popLoop();
          swTop--;
      }
    ;

case_list
    : /* empty */
    | case_list case_item
    ;

case_item
    : CASE expr COLON
      {
          /* mid-rule: check this case value */
          char *nextL = newLabel();
          char *chk   = newTemp();
          emit("%s = %s == %s;\n", chk, swExprStk[swTop], $2);
          emit("if (!(%s)) goto %s;\n", chk, nextL);
          auxPush(nextL);
      }
      stmt_list
      {
          /* After body: auto-break to switch end, then next-case label */
          emit("goto %s;\n", curBreak());
          emit("%s: ;\n",    auxPop());  /* FIX: null statement after label */
      }
    ;

default_opt
    : /* empty */
    | DEFAULT COLON stmt_list
    ;

/* ================================================================
   RETURN STATEMENT
   ================================================================ */
return_stmt
    : RETURN expr SEMICOLON   { emit("return %s;\n", $2); }
    | RETURN SEMICOLON        { emit("return;\n");         }
    ;

/* ================================================================
   BREAK  (hack)
   ================================================================ */
break_stmt
    : BREAK SEMICOLON
      {
          if (loopTop < 0)
              fprintf(stderr,
                  "Semantic Error at line %d: 'hack' outside loop/switch\n",
                  line_no);
          else
              emit("goto %s;\n", curBreak());
      }
    ;

/* ================================================================
   CONTINUE  (skip)
   ================================================================ */
continue_stmt
    : CONTINUE SEMICOLON
      {
          if (loopTop < 0)
              fprintf(stderr,
                  "Semantic Error at line %d: 'skip' outside loop\n",
                  line_no);
          else
              emit("goto %s;\n", curCont());
      }
    ;

/* ================================================================
   UNIQUE CYBERLANG FUNCTION CALLS
   (can appear as expressions or statements)
   ================================================================ */
func_call
    /* User-defined function calls */
    : IDENTIFIER LPAREN RPAREN
      {
          const char *ret = funcRetType($1);
          if (ret && strcmp(ret, "void") == 0) {
              emit("%s();\n", $1);
              $$ = strdup("0");
          } else {
              char *t = newTemp();
              emit("%s = %s();\n", t, $1);
              $$ = t;
          }
      }
    | IDENTIFIER LPAREN arg_list RPAREN
      {
          const char *ret = funcRetType($1);
          if (ret && strcmp(ret, "void") == 0) {
              emit("%s(%s);\n", $1, $3);
              $$ = strdup("0");
          } else {
              char *t = newTemp();
              emit("%s = %s(%s);\n", t, $1, $3);
              $$ = t;
          }
      }

    /* isPrime(n) – returns 1 if prime */
    | ISPRIME LPAREN expr RPAREN
      {
          char *t = newTemp();
          emit("%s = isPrime(%s);\n", t, $3);
          $$ = t;
      }

    /* now() – returns current timestamp */
    | NOW LPAREN RPAREN
      {
          char *t = newTemp();
          emit("%s = now();\n", t);
          $$ = t;
      }

    /* timeDiff(ts1, ts2) */
    | TIMEDIFF LPAREN expr COMMA expr RPAREN
      {
          char *t = newTemp();
          emit("%s = timeDiff(%s, %s);\n", t, $3, $5);
          $$ = t;
      }

    /* formatTime(ts, fmt) */
    | FORMAT_TIME LPAREN expr COMMA expr RPAREN
      {
                    char buf[1024];
                    snprintf(buf, sizeof(buf), "formatTime(%s, %s)", $3, $5);
                    $$ = strdup(buf);
      }

    /* parseTime(str, fmt) */
    | PARSE_TIME LPAREN expr COMMA expr RPAREN
      {
          char *t = newTemp();
          emit("%s = parseTime(%s, %s);\n", t, $3, $5);
          $$ = t;
      }
    ;

/* ================================================================
   EXPRESSIONS
   ================================================================
   Includes: arithmetic, comparison, logical (and/or/not/xor),
   unary minus, parenthesised exprs, identifiers, all literals,
   and function calls.
   Constant folding is applied to integer arithmetic.
   ================================================================ */
expr
    /* ---- Arithmetic ---- */
    : expr PLUS expr
      {
          char *fold = foldBinop('+', $1, $3);
          if (fold) {
              $$ = fold;  /* optimised: no temp emitted */
          } else {
              char *t = newTemp();
              emit("%s = %s + %s;\n", t, $1, $3);
              $$ = t;
          }
      }
    | expr MINUS expr
      {
          char *fold = foldBinop('-', $1, $3);
          if (fold) {
              $$ = fold;
          } else {
              char *t = newTemp();
              emit("%s = %s - %s;\n", t, $1, $3);
              $$ = t;
          }
      }
    | expr MULTIPLY expr
      {
          char *fold = foldBinop('*', $1, $3);
          if (fold) {
              $$ = fold;
          } else {
              char *t = newTemp();
              emit("%s = %s * %s;\n", t, $1, $3);
              $$ = t;
          }
      }
    | expr DIVIDE expr
      {
          char *fold = foldBinop('/', $1, $3);
          if (fold) {
              $$ = fold;
          } else {
              char *t = newTemp();
              emit("%s = %s / %s;\n", t, $1, $3);
              $$ = t;
          }
      }
    | expr MOD expr
      {
          char *fold = foldBinop('%', $1, $3);
          if (fold) {
              $$ = fold;
          } else {
              char *t = newTemp();
              emit("%s = %s %% %s;\n", t, $1, $3);
              $$ = t;
          }
      }

    /* ---- Comparison ---- */
    | expr GT  expr
      { char *t = newTemp(); emit("%s = %s > %s;\n",  t,$1,$3); $$ = t; }
    | expr LT  expr
      { char *t = newTemp(); emit("%s = %s < %s;\n",  t,$1,$3); $$ = t; }
    | expr GTE expr
      { char *t = newTemp(); emit("%s = %s >= %s;\n", t,$1,$3); $$ = t; }
    | expr LTE expr
      { char *t = newTemp(); emit("%s = %s <= %s;\n", t,$1,$3); $$ = t; }
    | expr EQ  expr
      { char *t = newTemp(); emit("%s = %s == %s;\n", t,$1,$3); $$ = t; }
    | expr NEQ expr
      { char *t = newTemp(); emit("%s = %s != %s;\n", t,$1,$3); $$ = t; }

    /* ---- Logical ---- */
    | expr AND expr
      { char *t = newTemp(); emit("%s = %s && %s;\n", t,$1,$3); $$ = t; }
    | expr OR  expr
      { char *t = newTemp(); emit("%s = %s || %s;\n",  t,$1,$3); $$ = t; }
    | expr XOR expr
      { char *t = newTemp(); emit("%s = ((%s && !%s) || (!%s && %s));\n", t,$1,$3,$1,$3); $$ = t; }
    | NOT expr
      { char *t = newTemp(); emit("%s = !(%s);\n",    t,$2);    $$ = t; }

    /* ---- Unary minus ---- */
    | MINUS expr  %prec UMINUS
      {
          if (isIntLit($2)) {
              /* fold constant negation */
              char buf[32];
              sprintf(buf, "%d", -atoi($2));
              $$ = strdup(buf);
          } else {
              char *t = newTemp();
              emit("%s = -(%s);\n", t, $2);
              $$ = t;
          }
      }

    /* ---- Parenthesised expression ---- */
    | LPAREN expr RPAREN
      { $$ = $2; }

    /* ---- Function call ---- */
    | func_call
      { $$ = $1; }

    /* ---- Atoms ---- */
    | IDENTIFIER
      { checkUse($1); $$ = $1; }
    | NUMBER
      {
          char buf[32];
          sprintf(buf, "%d", $1);
          $$ = strdup(buf);
      }
    | FLOATNUM
      {
          char buf[32];
          snprintf(buf, sizeof(buf), "%g", $1);
          $$ = strdup(buf);
      }
    | STRING
      { $$ = $1; }
    | CHARLIT
      { $$ = $1; }
    ;

%%

/* ================================================================
   ERROR HANDLER
   ================================================================ */
void yyerror(const char *s) {
    fprintf(stderr, "Syntax Error at line %d: %s\n", line_no, s);
}

/* ================================================================
   MAIN
   ================================================================ */
int main(int argc, char **argv) {
    if (argc > 1) {
        if (!freopen(argv[1], "r", stdin)) {
            perror(argv[1]);
            return 1;
        }
    }
    outFile = fopen("output.c", "w");
    if (!outFile) {
        perror("output.c");
        return 1;
    }
    emit("#include <stdio.h>\n");
    emit("#include <stdbool.h>\n");
    emit("#include \"cyberlang_builtins.h\"\n\n");
    yyparse();
    fclose(outFile);
    printf("Generated C output: output.c\n");
    return 0;
}
