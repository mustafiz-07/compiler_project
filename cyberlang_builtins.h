/* ================================================================
   cyberlang_builtins.h  –  CyberLang Built-in Runtime Functions
   ================================================================
   Include this file in every generated output.c so the compiler
   sees forward declarations (and inline implementations) for all
   unique CyberLang built-in functions:
     • isPrime(n)
     • now()
     • timeDiff(ts1, ts2)
     • formatTime(diff, fmt)
     • parseTime(str, fmt)
   ================================================================ */

#ifndef CYBERLANG_BUILTINS_H
#define CYBERLANG_BUILTINS_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <stdbool.h>

#if (defined(__unix__) || defined(__APPLE__)) && !defined(_XOPEN_SOURCE)
char *strptime(const char *s, const char *format, struct tm *tm);
#endif

/* ----------------------------------------------------------------
   isPrime(n)
   Returns 1 (true) if n is a prime number, 0 otherwise.
   ---------------------------------------------------------------- */
static inline int isPrime(int n) {
    if (n < 2) return 0;
    if (n == 2) return 1;
    if (n % 2 == 0) return 0;
    for (int i = 3; (long long)i * i <= (long long)n; i += 2)
        if (n % i == 0) return 0;
    return 1;
}

/* ----------------------------------------------------------------
   now()
   Returns the current wall-clock time as milliseconds since the
   Unix epoch (uses clock_gettime when available, falls back to
   time() * 1000).
   ---------------------------------------------------------------- */
static inline long long now(void) {
#if defined(_POSIX_TIMERS) && _POSIX_TIMERS > 0
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (long long)ts.tv_sec * 1000LL + (long long)(ts.tv_nsec / 1000000LL);
#else
    return (long long)time(NULL) * 1000LL;
#endif
}

/* ----------------------------------------------------------------
   timeDiff(ts1, ts2)
   Returns the absolute difference between two millisecond
   timestamps (as returned by now()).
   ---------------------------------------------------------------- */
static inline long long timeDiff(long long ts1, long long ts2) {
    long long d = ts2 - ts1;
    return d < 0 ? -d : d;
}

/* ----------------------------------------------------------------
   formatTime(diff_ms, unit)
   Converts a millisecond duration into a human-readable string.
   Supported unit strings: "ms", "s", "m", "h"
   Returns a pointer to a static buffer (not thread-safe, but
   sufficient for single-threaded CyberLang programs).
   ---------------------------------------------------------------- */
static inline const char* formatTime(long long diff_ms, const char *unit) {
    static char buf[64];
    if (!unit || strcmp(unit, "ms") == 0) {
        snprintf(buf, sizeof(buf), "%lld ms", diff_ms);
    } else if (strcmp(unit, "s") == 0) {
        snprintf(buf, sizeof(buf), "%.3f s", (double)diff_ms / 1000.0);
    } else if (strcmp(unit, "m") == 0) {
        snprintf(buf, sizeof(buf), "%.4f m", (double)diff_ms / 60000.0);
    } else if (strcmp(unit, "h") == 0) {
        snprintf(buf, sizeof(buf), "%.6f h", (double)diff_ms / 3600000.0);
    } else {
        /* Unknown unit: fall back to raw ms */
        snprintf(buf, sizeof(buf), "%lld ms", diff_ms);
    }
    return buf;
}

/* ----------------------------------------------------------------
   parseTime(str, fmt)
   Parses a date/time string according to a strptime-style format
   and returns a millisecond timestamp.
   Falls back to returning 0 if parsing fails or strptime is
   unavailable (e.g. on MSVC).
   ---------------------------------------------------------------- */
static inline long long parseTime(const char *str, const char *fmt) {
#if defined(__unix__) || defined(__APPLE__)
    struct tm t;
    memset(&t, 0, sizeof(t));
    t.tm_isdst = -1;
    if (strptime(str, fmt, &t) == NULL) return 0LL;
    time_t epoch = mktime(&t);
    return (epoch == (time_t)-1) ? 0LL : (long long)epoch * 1000LL;
#else
    
    (void)str; (void)fmt;
    return 0LL;
#endif
}

#endif
