/* washy — a featured, NO-FORK shell that compiles to ONE wasm command module and runs in our in-house
 * wasm lane (clang.wasm -> wasm32-wasip1 -> AOT -> wasmtime, per-invocation). This is "bash in WASM":
 * the only thing a real shell needs fork/exec for is pipes between processes — here pipes are done by
 * BUFFERED CHAINING in one process (run a stage to completion, feed its output to the next). No fork,
 * no exec, no wasmer. Tools are BUILTINS compiled in (busybox-style). Files are read/written over the
 * mounted /work dir (a virtual fs). Featured, not real-bash: enough grammar for an agent's batch work.
 *
 * Invocation:  sh.wasm "<command line>"   (the command line is argv[1]; the program's stdin is the
 *              optional external input to the first stage). Output -> stdout.
 *
 * v0 grammar: pipelines `|`, sequencing `;`, `&&`, `||`, redirects `>`/`>>`, simple quoting.
 * v0 builtins: echo cat grep head tail wc sort uniq rev tr cut nl true false  (+ upper/lower helpers).
 * Everything is intentionally small + extensible: add a builtin = one row in the dispatch table.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <ctype.h>
#include <fcntl.h>

/* ---- growable byte buffer (a "stream" between pipeline stages) ---------------------------------- */
typedef struct { char *p; size_t len, cap; } Buf;
static void bensure(Buf *b, size_t add) {
  if (b->len + add + 1 > b->cap) { b->cap = (b->len + add + 1) * 2 + 64; b->p = realloc(b->p, b->cap); }
}
static void bput(Buf *b, const char *s, size_t n) { bensure(b, n); memcpy(b->p + b->len, s, n); b->len += n; b->p[b->len] = 0; }
static void bputs(Buf *b, const char *s) { bput(b, s, strlen(s)); }
static void bputc_(Buf *b, char c) { bensure(b, 1); b->p[b->len++] = c; b->p[b->len] = 0; }
static void bfree(Buf *b) { free(b->p); b->p = 0; b->len = b->cap = 0; }

/* read a whole file from the cwd (/work) into a buffer; 0 on success */
static int read_file(const char *path, Buf *out) {
  int fd = open(path, O_RDONLY);
  if (fd < 0) return -1;
  char tmp[8192]; long n;
  while ((n = read(fd, tmp, sizeof tmp)) > 0) bput(out, tmp, (size_t)n);
  close(fd);
  return 0;
}

/* ---- builtins: each takes argv + an input stream, writes to an output stream --------------------- */
typedef struct { int argc; char **argv; Buf *in; Buf *out; } Ctx;

static void each_line(Buf *in, void (*fn)(const char *line, size_t len, void *u), void *u) {
  size_t i = 0;
  while (i < in->len) {
    size_t j = i;
    while (j < in->len && in->p[j] != '\n') j++;
    fn(in->p + i, j - i, u);
    i = (j < in->len) ? j + 1 : j;
  }
}

static int b_echo(Ctx *c) {
  for (int i = 1; i < c->argc; i++) { if (i > 1) bputc_(c->out, ' '); bputs(c->out, c->argv[i]); }
  bputc_(c->out, '\n'); return 0;
}
static int b_cat(Ctx *c) {
  if (c->argc <= 1) { bput(c->out, c->in->p, c->in->len); return 0; }
  int rc = 0;
  for (int i = 1; i < c->argc; i++) { Buf f = {0}; if (read_file(c->argv[i], &f) == 0) bput(c->out, f.p, f.len); else { bputs(c->out, "cat: "); bputs(c->out, c->argv[i]); bputs(c->out, ": No such file\n"); rc = 1; } bfree(&f); }
  return rc;
}
struct grep_u { const char *pat; Buf *out; int inv; };
static void grep_line(const char *l, size_t n, void *u) {
  struct grep_u *g = u; char *line = strndup(l, n);
  int hit = strstr(line, g->pat) != NULL;
  if (hit ^ g->inv) { bput(g->out, l, n); bputc_(g->out, '\n'); }
  free(line);
}
static int b_grep(Ctx *c) {
  int inv = 0, ai = 1;
  if (ai < c->argc && strcmp(c->argv[ai], "-v") == 0) { inv = 1; ai++; }
  if (ai >= c->argc) { bputs(c->out, "grep: need a pattern\n"); return 2; }
  struct grep_u g = { c->argv[ai], c->out, inv };
  /* additional file args: grep over those instead of stdin */
  if (ai + 1 < c->argc) { for (int i = ai + 1; i < c->argc; i++) { Buf f = {0}; if (read_file(c->argv[i], &f) == 0) each_line(&f, grep_line, &g); bfree(&f); } }
  else each_line(c->in, grep_line, &g);
  return 0;
}
struct nlim { int n, seen; Buf *out; };
static void head_line(const char *l, size_t n, void *u) { struct nlim *h = u; if (h->seen < h->n) { bput(h->out, l, n); bputc_(h->out, '\n'); h->seen++; } }
static int b_head(Ctx *c) { int n = 10, ai = 1; if (ai < c->argc && c->argv[ai][0] == '-') { n = atoi(c->argv[ai] + 1); ai++; } struct nlim h = { n, 0, c->out }; each_line(c->in, head_line, &h); return 0; }
static int count_lines(Buf *b) { int n = 0; for (size_t i = 0; i < b->len; i++) if (b->p[i] == '\n') n++; return n; }
static int b_tail(Ctx *c) {
  int n = 10, ai = 1; if (ai < c->argc && c->argv[ai][0] == '-') { n = atoi(c->argv[ai] + 1); ai++; }
  int total = count_lines(c->in), skip = total - n; if (skip < 0) skip = 0;
  struct nlim h = { 1<<30, 0, c->out }; (void)h;
  int seen = 0; size_t i = 0;
  while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; if (seen >= skip) { bput(c->out, c->in->p + i, j - i); bputc_(c->out, '\n'); } seen++; i = (j < c->in->len) ? j + 1 : j; }
  return 0;
}
static int b_wc(Ctx *c) {
  long lines = 0, words = 0, bytes = (long)c->in->len; int inw = 0;
  for (size_t i = 0; i < c->in->len; i++) { char ch = c->in->p[i]; if (ch == '\n') lines++; if (isspace((unsigned char)ch)) inw = 0; else if (!inw) { inw = 1; words++; } }
  char t[64]; int wantl = 0, wantw = 0, wantc = 0;
  for (int i = 1; i < c->argc; i++) { if (!strcmp(c->argv[i], "-l")) wantl = 1; else if (!strcmp(c->argv[i], "-w")) wantw = 1; else if (!strcmp(c->argv[i], "-c")) wantc = 1; }
  if (!wantl && !wantw && !wantc) { snprintf(t, sizeof t, "%ld %ld %ld\n", lines, words, bytes); bputs(c->out, t); }
  else { if (wantl) { snprintf(t, sizeof t, "%ld\n", lines); bputs(c->out, t); } if (wantw) { snprintf(t, sizeof t, "%ld\n", words); bputs(c->out, t); } if (wantc) { snprintf(t, sizeof t, "%ld\n", bytes); bputs(c->out, t); } }
  return 0;
}
static int b_rev(Ctx *c) {
  size_t i = 0; while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; for (size_t k = j; k > i; k--) bputc_(c->out, c->in->p[k - 1]); bputc_(c->out, '\n'); i = (j < c->in->len) ? j + 1 : j; }
  return 0;
}
static int cmp_lines(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
static int b_sort(Ctx *c) {
  int nl = count_lines(c->in) + 1; char **arr = calloc(nl, sizeof(char *)); int n = 0; size_t i = 0;
  while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; arr[n++] = strndup(c->in->p + i, j - i); i = (j < c->in->len) ? j + 1 : j; }
  qsort(arr, n, sizeof(char *), cmp_lines);
  int rev = 0; for (int k = 1; k < c->argc; k++) if (!strcmp(c->argv[k], "-r")) rev = 1;
  /* free the pointer we just emitted (NOT arr[k]) — under -r, arr[k] may already be freed (use-after-free) */
  for (int k = 0; k < n; k++) { char *s = arr[rev ? n - 1 - k : k]; bputs(c->out, s); bputc_(c->out, '\n'); free(s); }
  free(arr); return 0;
}
static int b_uniq(Ctx *c) {
  char *prev = 0; size_t i = 0;
  while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; char *line = strndup(c->in->p + i, j - i); if (!prev || strcmp(prev, line) != 0) { bputs(c->out, line); bputc_(c->out, '\n'); } free(prev); prev = line; i = (j < c->in->len) ? j + 1 : j; }
  free(prev); return 0;
}
/* expand a tr SET, turning `a-z` ranges into the full sequence; returns a malloc'd string. */
static char *tr_expand(const char *s) {
  Buf b = {0};
  for (size_t i = 0; s[i]; i++) {
    if (s[i + 1] == '-' && s[i + 2] && s[i + 2] != 0) { for (char ch = s[i]; ch <= s[i + 2]; ch++) bputc_(&b, ch); i += 2; }
    else bputc_(&b, s[i]);
  }
  return b.p ? b.p : strdup("");
}
static int b_tr(Ctx *c) {
  if (c->argc < 3) { bputs(c->out, "tr: need SET1 SET2\n"); return 2; }
  char *a = tr_expand(c->argv[1]), *b = tr_expand(c->argv[2]); size_t la = strlen(a), lb = strlen(b);
  for (size_t i = 0; i < c->in->len; i++) { char ch = c->in->p[i]; const char *pos = memchr(a, ch, la); if (pos) { size_t idx = (size_t)(pos - a); bputc_(c->out, idx < lb ? b[idx] : b[lb ? lb - 1 : 0]); } else bputc_(c->out, ch); }
  free(a); free(b);
  return 0;
}
static int b_upper(Ctx *c) { for (size_t i = 0; i < c->in->len; i++) bputc_(c->out, (char)toupper((unsigned char)c->in->p[i])); return 0; }
static int b_lower(Ctx *c) { for (size_t i = 0; i < c->in->len; i++) bputc_(c->out, (char)tolower((unsigned char)c->in->p[i])); return 0; }
static int b_nl(Ctx *c) { int ln = 1; size_t i = 0; char t[32]; while (i < c->in->len) { size_t j = i; while (j < c->in->len && c->in->p[j] != '\n') j++; snprintf(t, sizeof t, "%6d\t", ln++); bputs(c->out, t); bput(c->out, c->in->p + i, j - i); bputc_(c->out, '\n'); i = (j < c->in->len) ? j + 1 : j; } return 0; }
static int b_true(Ctx *c) { (void)c; return 0; }
static int b_false(Ctx *c) { (void)c; return 1; }
/* the virtual FS is flat (path keys), so directories are implicit: `mkdir`/`mkdir -p` is a no-op that
 * succeeds — a redirect to `/work/sub/f.txt` creates the key directly (flushed to disk with its parent). */
static int b_mkdir(Ctx *c) { (void)c; return 0; }

typedef int (*Builtin)(Ctx *);
/* Builtins are now ONLY: (a) tools coreutils LACKS (grep), (b) our own helpers (upper/lower), and
 * (c) trivial fast-path commands (echo/true/false). Everything coreutils provides (cat/head/tail/wc/
 * sort/uniq/tr/nl/cut/seq/…) delegates to REAL coreutils via host_exec — which, unlike our stdin-only
 * builtins, correctly handles FILE ARGUMENTS and the full flag set. */
static struct { const char *name; Builtin fn; } TABLE[] = {
  {"echo", b_echo}, {"grep", b_grep}, {"rev", b_rev}, {"mkdir", b_mkdir},
  {"upper", b_upper}, {"lower", b_lower}, {"true", b_true}, {"false", b_false}, {0, 0}
};
static Builtin lookup(const char *name) { for (int i = 0; TABLE[i].name; i++) if (!strcmp(TABLE[i].name, name)) return TABLE[i].fn; return 0; }

/* host_exec — the thesis's fork/exec emulation. A command that isn't a builtin is delegated to the
 * HOST, which runs that program's wasm module (e.g. coreutils) and returns its output. So the shell
 * provides GRAMMAR; the host provides the full tool set. host_exec returns the output length (or -1 if
 * the program isn't found); host_exec_read copies the bytes into our buffer + returns the exit code. */
__attribute__((import_module("env"), import_name("host_exec")))
extern int host_exec(const char *cmd, int cmdlen, const char *in, int inlen);
__attribute__((import_module("env"), import_name("host_exec_read")))
extern int host_exec_read(char *buf);

/* ---- tokenizer: split a stage into argv, honoring '...' and "..." quotes ------------------------ */
static int tokenize(char *s, char **argv, int max) {
  int n = 0;
  while (*s && n < max - 1) {
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) break;
    char *start; char q = 0;
    if (*s == '\'' || *s == '"') { q = *s++; start = s; while (*s && *s != q) s++; }
    else { start = s; while (*s && *s != ' ' && *s != '\t') s++; }
    if (*s) *s++ = 0;
    argv[n++] = start;
  }
  argv[n] = 0;
  return n;
}

/* ---- variables + expansion + lexer (the grammar layer) ----------------------------------------- */
#define MAXVARS 256
static struct { char *name, *val; } VARS[MAXVARS]; static int NVARS = 0;
static const char *var_get(const char *name) { for (int i = 0; i < NVARS; i++) if (!strcmp(VARS[i].name, name)) return VARS[i].val; return ""; }
static void var_set(const char *name, const char *val) {
  for (int i = 0; i < NVARS; i++) if (!strcmp(VARS[i].name, name)) { free(VARS[i].val); VARS[i].val = strdup(val); return; }
  if (NVARS < MAXVARS) { VARS[NVARS].name = strdup(name); VARS[NVARS].val = strdup(val); NVARS++; }
}
static int is_assign(const char *w) { if (!isalpha((unsigned char)*w) && *w != '_') return 0; const char *p = w; while (*p && (isalnum((unsigned char)*p) || *p == '_')) p++; return *p == '='; }

/* expand $VAR and ${VAR} in `s` → a malloc'd string (command substitution $() is a later addition) */
static char *expand(const char *s) {
  Buf b = {0};
  for (const char *p = s; *p; ) {
    if (*p == '$' && (isalnum((unsigned char)p[1]) || p[1] == '_' || p[1] == '{')) {
      p++; char name[128]; int n = 0;
      if (*p == '{') { p++; while (*p && *p != '}' && n < 127) name[n++] = *p++; if (*p == '}') p++; }
      else { while ((isalnum((unsigned char)*p) || *p == '_') && n < 127) name[n++] = *p++; }
      name[n] = 0; bputs(&b, var_get(name));
    } else bputc_(&b, *p++);
  }
  return b.p ? b.p : strdup("");
}

/* lex the whole input into words; ';' and newline become standalone ";" tokens; quotes are honored
 * then stripped. `|`, `>`, `&&`, `||` stay inside a word-run (run_line handles them per simple statement). */
static int lex(char *s, char **w, int max) {
  int n = 0;
  while (*s && n < max - 1) {
    while (*s == ' ' || *s == '\t') s++;
    if (!*s) break;
    if (*s == ';' || *s == '\n') { w[n++] = ";"; s++; continue; }
    char *start; char q = 0;
    if (*s == '\'' || *s == '"') { q = *s++; start = s; while (*s && *s != q) s++; if (*s) *s++ = 0; w[n++] = start; continue; }
    start = s;
    while (*s && *s != ' ' && *s != '\t' && *s != ';' && *s != '\n') s++;
    char term = *s; if (*s) *s++ = 0;
    w[n++] = start;
    if (term == ';' || term == '\n') { if (n < max - 1) w[n++] = ";"; }
  }
  w[n] = 0;
  return n;
}

/* run one pipeline (stages split by '|'); `extern_in` seeds the FIRST stage. Returns exit code; the
 * final stage's output is written to real stdout (or a redirect file). NO FORK — each stage runs to
 * completion and its buffer becomes the next stage's input. */
static int run_pipeline(char *pipe_str, Buf *extern_in) {
  /* split off a trailing redirect: `… > file` or `… >> file` */
  char *redir = 0; int append = 0;
  char *gt = strstr(pipe_str, ">");
  if (gt) { append = (gt[1] == '>'); *gt = 0; char *f = gt + (append ? 2 : 1); while (*f == ' ') f++; redir = f; char *e = f; while (*e && *e != ' ') e++; *e = 0; }

  Buf cur = {0};
  if (extern_in && extern_in->len) bput(&cur, extern_in->p, extern_in->len);

  int rc = 0; char *save; char *stage = strtok_r(pipe_str, "|", &save);
  while (stage) {
    char *argv[128]; int argc = tokenize(stage, argv, 128);
    Buf next = {0};
    if (argc == 0) { bfree(&next); stage = strtok_r(0, "|", &save); continue; }
    Builtin fn;
    if (argc == 1 && is_assign(argv[0])) {
      /* a lone NAME=val stage is an assignment (valid in a `&&`/`;` chain), not a command */
      char *eq = strchr(argv[0], '='); *eq = 0; char *v = expand(eq + 1); var_set(argv[0], v); free(v); *eq = '='; rc = 0;
    }
    else if ((fn = lookup(argv[0]))) { Ctx ctx = { argc, argv, &cur, &next }; rc = fn(&ctx); }
    else {
      /* not a builtin → delegate to the host (runs the real program over `cur` as stdin) */
      Buf cmd = {0};
      for (int i = 0; i < argc; i++) { if (i) bputc_(&cmd, ' '); bputs(&cmd, argv[i]); }
      int out_len = host_exec(cmd.p ? cmd.p : "", (int)cmd.len, cur.p ? cur.p : "", (int)cur.len);
      bfree(&cmd);
      if (out_len >= 0) {
        bensure(&next, (size_t)out_len + 1);
        rc = host_exec_read(next.p + next.len);
        next.len += out_len; next.p[next.len] = 0;
      } else { bputs(&next, argv[0]); bputs(&next, ": command not found\n"); rc = 127; }
    }
    bfree(&cur); cur = next;
    stage = strtok_r(0, "|", &save);
  }

  if (redir) { int fd = open(redir, O_WRONLY | O_CREAT | (append ? O_APPEND : O_TRUNC), 0644); if (fd >= 0) { write(fd, cur.p, cur.len); close(fd); } }
  else write(1, cur.p, cur.len);
  bfree(&cur);
  return rc;
}

/* split the whole line on `;`, `&&`, `||` and run each pipeline with short-circuit semantics. */
static int run_line(char *line, Buf *extern_in) {
  int rc = 0; char *p = line; char last_sep = ';';   /* local: short-circuit state never leaks across calls */
  while (*p) {
    /* find the next separator */
    char *q = p; char sep = ';';
    while (*q) { if (*q == ';') { sep = ';'; break; } if (q[0] == '&' && q[1] == '&') { sep = '&'; break; } if (q[0] == '|' && q[1] == '|') { sep = 'o'; break; } q++; }
    char *seg = p;
    if (*q) { *q = 0; p = q + ((sep == '&' || sep == 'o') ? 2 : 1); } else p = q;
    /* trim */
    while (*seg == ' ') seg++;
    if (*seg) {
      int prev = rc;
      /* short-circuit: after `&&` skip if prev failed; after `||` skip if prev succeeded */
      int skip = (last_sep == '&' && prev != 0) || (last_sep == 'o' && prev == 0);
      if (!skip) rc = run_pipeline(seg, (seg == line) ? extern_in : 0);
      last_sep = sep;
    }
  }
  return rc;
}

/* run a simple statement string: expand $VARs, then hand to run_line (which does &&/||/| + redirects) */
static int run_simple(char *cmd, Buf *extern_in) {
  char *e = expand(cmd);
  int rc = run_line(e, extern_in);
  free(e);
  return rc;
}

/* execute the word-stream statements in [s, e): the GRAMMAR engine — for/if/while/assignment, else a
 * simple statement. `for`/`while` bodies and `if` branches recurse here. extern_in seeds only the first. */
static int join_until(char **w, int *i, int e, Buf *out) {   /* collect words into `out` until ";" / end; returns words taken */
  int started = 0, took = 0;
  while (*i < e && strcmp(w[*i], ";")) { if (started) bputc_(out, ' '); bputs(out, w[*i]); started = 1; (*i)++; took++; }
  return took;
}

static int run_range(char **w, int s, int e, Buf *extern_in) {
  int rc = 0, i = s;
  while (i < e) {
    if (!strcmp(w[i], ";")) { i++; continue; }

    if (!strcmp(w[i], "for") && i + 2 < e) {                 /* for NAME in V…; do BODY; done */
      char *name = w[i + 1]; int vi = i + 3;                 /* skip "in" at i+2 */
      char *vals[256]; int nv = 0;
      while (vi < e && strcmp(w[vi], ";") && strcmp(w[vi], "do") && nv < 256) vals[nv++] = w[vi++];
      while (vi < e && !strcmp(w[vi], ";")) vi++;
      if (vi < e && !strcmp(w[vi], "do")) {
        int bstart = vi + 1, depth = 1, j = bstart;
        while (j < e && depth > 0) { if (!strcmp(w[j], "do")) depth++; else if (!strcmp(w[j], "done")) { if (--depth == 0) break; } j++; }
        for (int k = 0; k < nv; k++) { char *ev = expand(vals[k]); var_set(name, ev); free(ev); rc = run_range(w, bstart, j, 0); }
        i = j + 1;
      } else i = vi;
      continue;
    }

    if (!strcmp(w[i], "while") && i + 1 < e) {               /* while COND; do BODY; done */
      Buf cond = {0}; int j = i + 1;
      while (j < e && strcmp(w[j], ";") && strcmp(w[j], "do")) { if (cond.len) bputc_(&cond, ' '); bputs(&cond, w[j]); j++; }
      while (j < e && !strcmp(w[j], ";")) j++;
      if (j < e && !strcmp(w[j], "do")) {
        int bstart = j + 1, depth = 1, k = bstart;
        while (k < e && depth > 0) { if (!strcmp(w[k], "do")) depth++; else if (!strcmp(w[k], "done")) { if (--depth == 0) break; } k++; }
        int guard = 0;
        while (guard++ < 1000000) { char *c = cond.p ? strdup(cond.p) : strdup("true"); int cr = run_simple(c, 0); free(c); if (cr != 0) break; rc = run_range(w, bstart, k, 0); }
        i = k + 1;
      } else i = j;
      bfree(&cond);
      continue;
    }

    if (!strcmp(w[i], "if") && i + 1 < e) {                  /* if COND; then BODY; [else BODY;] fi */
      Buf cond = {0}; int j = i + 1;
      while (j < e && strcmp(w[j], ";") && strcmp(w[j], "then")) { if (cond.len) bputc_(&cond, ' '); bputs(&cond, w[j]); j++; }
      while (j < e && !strcmp(w[j], ";")) j++;
      if (j < e && !strcmp(w[j], "then")) {
        int tstart = j + 1, depth = 1, k = tstart, elsep = -1, endp = -1;
        while (k < e && depth > 0) {
          if (!strcmp(w[k], "if")) depth++;
          else if (!strcmp(w[k], "fi")) { if (--depth == 0) { endp = k; break; } }
          else if (depth == 1 && !strcmp(w[k], "else") && elsep < 0) elsep = k;
          k++;
        }
        if (endp < 0) endp = e;
        char *c = cond.p ? strdup(cond.p) : strdup("true"); int cr = run_simple(c, 0); free(c);
        if (cr == 0) rc = run_range(w, tstart, elsep >= 0 ? elsep : endp, 0);
        else if (elsep >= 0) rc = run_range(w, elsep + 1, endp, 0);
        i = endp + 1;
      } else i = j;
      bfree(&cond);
      continue;
    }

    if (is_assign(w[i]) && (i + 1 >= e || !strcmp(w[i + 1], ";"))) {   /* NAME=VALUE */
      char *eq = strchr(w[i], '='); *eq = 0; char *val = expand(eq + 1); var_set(w[i], val); free(val); *eq = '='; i++;
      continue;
    }

    /* simple statement: join words until ';' and run */
    Buf cmd = {0}; join_until(w, &i, e, &cmd);
    if (cmd.len) rc = run_simple(cmd.p, extern_in);
    extern_in = 0;
    bfree(&cmd);
  }
  return rc;
}

int main(int argc, char **argv) {
  Buf line = {0}, in = {0};
  if (argc >= 2) {
    /* command line via argv[1..]; the program's stdin is external data for the first stage. */
    for (int i = 1; i < argc; i++) { if (i > 1) bputc_(&line, ' '); bputs(&line, argv[i]); }
    char t[8192]; long n; while ((n = read(0, t, sizeof t)) > 0) bput(&in, t, (size_t)n);
  } else {
    /* no argv: the WHOLE stdin IS the command line (the agent's bash line). No external data — the
     * shell's inputs come from files in /work (cat /work/x | …). This is the run_command(wasm,line) path. */
    char t[8192]; long n; while ((n = read(0, t, sizeof t)) > 0) bput(&line, t, (size_t)n);
    /* strip a trailing newline so `echo hi\n` parses as `echo hi` */
    while (line.len && (line.p[line.len - 1] == '\n' || line.p[line.len - 1] == '\r')) line.p[--line.len] = 0;
  }
  /* lex into words + run through the grammar engine (for/if/while/vars), which falls back to run_line
   * for simple statements. The word array points INTO line.p (lex nul-terminates in place). */
  char *words[4096]; int nw = lex(line.p ? line.p : "", words, 4096);
  int rc = run_range(words, 0, nw, &in);
  bfree(&line); bfree(&in);
  /* WASI rejects exit codes outside [0,125] — clamp (the failure detail is in the output text). */
  if (rc < 0 || rc > 125) rc = 1;
  return rc;
}
