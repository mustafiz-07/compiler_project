/* ================================================================
   cyberlang.l  -  Flex Lexer for CyberLang (Cyberpunk C-variant)
   ================================================================ */

%{
#include "cyberlang.tab.h"
#include <stdlib.h>
#include <string.h>

int line_no = 1;
%}

%x MLCOMMENT

digit    [0-9]
letter   [a-zA-Z_]
id       {letter}({letter}|{digit})*

%%

"@inject"         { return INJECT;      }
"@macro"          { return MACRO;       }

"byte"            { return BYTE;        }
"deci"            { return DECI;        }
"bigdeci"         { return BIGDECI;     }
"megabyte"        { return MEGABYTE;    }
"symbol"          { return SYMBOL_TYPE; }
"binary"          { return BINARY;      }
"timestamp"       { return TIMESTAMP;   }
"void"            { return VOID;        }

"bootup"          { return BOOTUP;      }
"cyber"           { return CYBER;       }

"green"           { return IF;          }
"yellow"          { return ELSEIF;      }
"red"             { return ELSE;        }
"round"           { return FOR;         }
"repeat"          { return WHILE;       }
"execute"         { return DO;          }
"skip"            { return CONTINUE;    }
"hack"            { return BREAK;       }

"matrix"          { return SWITCH;      }
"node"            { return CASE;        }
"default"         { return DEFAULT;     }

"send"            { return RETURN;      }

"and"             { return AND;         }
"or"              { return OR;          }
"not"             { return NOT;         }
"xor"             { return XOR;         }

"display"         { return DISPLAY;     }
"capture"         { return CAPTURE;     }

"isPrime"         { return ISPRIME;     }
"now"             { return NOW;         }
"timeDiff"        { return TIMEDIFF;    }
"formatTime"      { return FORMAT_TIME; }
"parseTime"       { return PARSE_TIME;  }

"<<"              { return ASSIGN;      }
"=>"              { return ARROW;       }
"++"              { return INC;         }
"--"              { return DEC;         }
">="              { return GTE;         }
"<="              { return LTE;         }
"=="              { return EQ;          }
"!="              { return NEQ;         }

">"               { return GT;          }
"<"               { return LT;          }
"+"               { return PLUS;        }
"-"               { return MINUS;       }
"*"               { return MULTIPLY;    }
"/"               { return DIVIDE;      }
"%"               { return MOD;         }

";"               { return SEMICOLON;   }
","               { return COMMA;       }
":"               { return COLON;       }
"("               { return LPAREN;      }
")"               { return RPAREN;      }
"{"               { return LBRACE;      }
"}"               { return RBRACE;      }

{digit}+                {
                            yylval.intval   = atoi(yytext);
                            return NUMBER;
                        }

{digit}+"."{digit}+     {
                            yylval.floatval = atof(yytext);
                            return FLOATNUM;
                        }

\"[^\"]*\"              {
                            yylval.str = strdup(yytext);
                            return STRING;
                        }

\'[^\']*\'              {
                            yylval.str = strdup(yytext);
                            return CHARLIT;
                        }

{id}                    {
                            yylval.str = strdup(yytext);
                            return IDENTIFIER;
                        }

"//".*                  { }

"#{"                    { BEGIN(MLCOMMENT); }
<MLCOMMENT>"}#"         { BEGIN(INITIAL);   }
<MLCOMMENT>\n           { line_no++;        }
<MLCOMMENT>.            { }

[ \t\r]+                { }
\n                      { line_no++; }

.                       {
                            fprintf(stderr,
                                "Lexical Error at line %d: "
                                "unknown character '%s'\n",
                                line_no, yytext);
                        }

%%

int yywrap(void) { return 1; }
