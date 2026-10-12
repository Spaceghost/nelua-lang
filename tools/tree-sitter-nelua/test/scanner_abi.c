/* Independent Tree-sitter foreign-ABI/lexer oracle, not production scanner logic. */
#include "tree_sitter/parser.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>
typedef struct { TSLexer lexer; const char *text; size_t position, end; } Probe;
bool tree_sitter_nelua_external_scanner_scan(void *, TSLexer *, const bool *);
void *tree_sitter_nelua_external_scanner_create(void);
unsigned tree_sitter_nelua_external_scanner_serialize(void *, char *);
void tree_sitter_nelua_external_scanner_deserialize(void *, const char *, unsigned);
void tree_sitter_nelua_external_scanner_destroy(void *);
static void advance(TSLexer *lexer, bool skip) {
    (void)skip; Probe *p=(Probe *)lexer;
    if (p->text[p->position]) ++p->position;
    lexer->lookahead=(unsigned char)p->text[p->position];
}
static void mark(TSLexer *lexer) { Probe *p=(Probe *)lexer;p->end=p->position; }
static bool eof(const TSLexer *lexer) { const Probe *p=(const Probe *)lexer;return p->text[p->position]=='\0'; }
static void check(const char *text, bool accept, unsigned token, size_t end) {
    Probe p={0};p.text=text;p.lexer.lookahead=(unsigned char)text[0];
    p.lexer.advance=advance;p.lexer.mark_end=mark;p.lexer.eof=eof;
    const bool valid[]={true,true,true};
    assert(tree_sitter_nelua_external_scanner_scan(NULL,&p.lexer,valid)==accept);
    if (accept) { assert(p.lexer.result_symbol==token);assert(p.end==end); }
}
int main(void) {
    check("[[x]]rest",true,0,5);
    check("[==[a]=]b]==]rest",true,0,12);
    check("[==[unterminated]=]",false,0,0);
    check("[=oops",false,0,0);
    check("-- short\nrest",true,1,8);
    check("--[=[comment]=]rest",true,1,15);
    check("## raw\nrest",true,2,6);
    check("##[=[Lua]=]rest",true,2,11);
    check(" \t[[x]]rest",true,0,7);
    char text[600];size_t n=0;text[n++]='[';
    for(unsigned i=0;i<200;++i)text[n++]='=';
    text[n++]='[';text[n++]='x';text[n++]=']';
    for(unsigned i=0;i<200;++i)text[n++]='=';
    text[n++]=']';text[n]='\0';check(text,true,0,n);
    void *payload=tree_sitter_nelua_external_scanner_create();char buffer[1024];
    assert(tree_sitter_nelua_external_scanner_serialize(payload,buffer)==0);
    tree_sitter_nelua_external_scanner_deserialize(payload,buffer,0);
    tree_sitter_nelua_external_scanner_destroy(payload);
    puts("Nelua scanner foreign ABI: exact/200-level delimiters, EOF refusal and stateless lifecycle PASS");
    return 0;
}
