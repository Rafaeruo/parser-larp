/* Parser da linguagem LARP: analise sintatica + analise semantica feita por
 * TRADUCAO DIRIGIDA POR SINTAXE (TDS).
 *
 * A gramatica (BNF) e a mesma da versao anterior. O que mudou: as producoes agora tem ACOES
 * SEMANTICAS e os simbolos da gramatica carregam ATRIBUTOS (%union / %type).
 *
 * Atributos usados:
 *   - TIPO (token)                 -> <tipo>   o tipo escrito na declaracao (int/float/string)
 *   - ID (token)                   -> <nome>   o lexema do identificador
 *   - literal, fator, termo,
 *     expressao, valor, ternario   -> <tipo>   tipo da expressao (SINTETIZADO: sobe das folhas
 *                                              para a raiz, ex.: expressao.tipo = f(expressao1.tipo, termo.tipo))
 *   - lista_ids                    -> <ids>    nomes (e linhas) declarados, na ordem
 *   - lista_expressoes             -> <tipos>  tipo de cada valor de uma declaracao
 *   - operador_relacional          -> <inteiro> 1 se for == ou !=, 0 se for de ordem (<, <=, >, >=)
 *
 * Atributos "herdados" (informacao que desce da gramatica, que o Bison/LR nao tem nativamente)
 * sao simulados com estado global manipulado por acoes no meio da regra:
 *   - pilha de escopos             -> acoes em bloco e nos ramos do ternario
 *   - pilha_de_routes              -> tipo da expressao do route, consultado por cada valor de case
 *   - profundidade_de_cases        -> usada para validar que "fall" so aparece dentro de um case
 *
 * Verificacoes semanticas feitas:
 *   1. variavel redeclarada no mesmo escopo
 *   2. variavel usada sem declaracao
 *   3. string em operacao aritmetica (+ - * /)
 *   4. tipos incompativeis em atribuicao/declaracao (int <- float e string <-> numero sao erros;
 *      float <- int e permitido)
 *   5. quantidade de valores diferente da quantidade de variaveis em "tipo a, b = x, y;"
 *   6. comparacao invalida na condicao (string com numero; string com <, <=, >, >=)
 *   7. ramos do ternario com tipos incompativeis
 *   8. route sobre float; valor de case com tipo diferente da expressao do route
 *   9. "fall" fora de um case
 *
 * Erros semanticos nao interrompem o parse: sao contados e reportados no formato
 *   [LARP] ERRO SEMANTICO na linha N: mensagem
 * O tipo especial T_ERRO e propagado silenciosamente para nao gerar erros em cascata.
 */

    /* Tipos usados dentro do %union: precisam existir antes dele (e tambem no parser.tab.h, que o
     * clarker.l inclui) */
%code requires {
#include <string>
#include <vector>

enum Tipo { T_ERRO, T_INT, T_FLOAT, T_STRING };

struct Identificador {
    std::string nome;
    int         linha;
};
}

    /* Mensagens de erro dizem o que era esperado ("unexpected X, expecting Y") */
%define parse.error detailed

    /* Habilita @n.first_line: o clarker.l preenche yylloc a cada token */
%locations

    /* Copiado para o parser.tab.h, que o clarker.l tambem inclui: o nome da linguagem, usado nas
     * mensagens do lexer e do parser, fica definido num lugar so */
%code provides {
#define NOME_DA_LINGUAGEM "LARP"
}

    /* Declaracoes, estado e funcoes auxiliares usadas pelas acoes semanticas */
%code {
#include <cstdarg>
#include <cstdio>
#include <map>

int  yylex(void);                   // gerada pelo Flex a partir do clarker.l
void yyerror(const char *mensagem); // chamada pelo Bison quando encontra um erro de sintaxe

extern int yylineno;               // mantida pelo Flex (%option yylineno)
extern int total_de_erros_lexicos; // contado pelo clarker.l

// Estado da analise semantica

// Uma linha da tabela de simbolos
struct Variavel {
    std::string nome;
    Tipo        tipo;
    int         linha_declaracao;
    int         escopo;  // 0 = global
    int         usos;    // leituras e atribuicoes depois da declaracao
};

static std::vector<Variavel> variaveis; // todas as variaveis, na ordem em que foram declaradas

// Pilha de escopos: cada escopo mapeia nome -> indice em "variaveis". Comeca com o escopo global
static std::vector< std::map<std::string, int> > escopos(1);

static std::vector<Tipo> pilha_de_routes;     // tipo da expressao de cada route "aberto"
static int profundidade_de_cases = 0;         // quantos cases estamos dentro (fall so vale se > 0)
static int total_de_erros_semanticos = 0;

// Utilitarios

static const char *nome_do_tipo(Tipo t)
{
    switch (t) {
    case T_INT:    return "int";
    case T_FLOAT:  return "float";
    case T_STRING: return "string";
    default:       return "?";
    }
}

static void erro_semantico(int linha, const char *formato, ...)
{
    va_list argumentos;

    total_de_erros_semanticos++;
    printf("[%s] ERRO SEMANTICO na linha %d: ", NOME_DA_LINGUAGEM, linha);

    va_start(argumentos, formato);
    vprintf(formato, argumentos);
    va_end(argumentos);

    printf("\n");
}

static Identificador novo_identificador(const std::string &nome, int linha)
{
    Identificador id;
    id.nome  = nome;
    id.linha = linha;
    return id;
}

// Tabela de simbolos e escopos

static void entrar_escopo(void)
{
    escopos.push_back(std::map<std::string, int>());
}

static void sair_escopo(void)
{
    escopos.pop_back();
}

// Declara uma variavel no escopo atual. Redeclarar no MESMO escopo e erro; esconder (shadowing)
// uma variavel de um escopo externo e permitido
static void declarar(const std::string &nome, Tipo tipo, int linha)
{
    std::map<std::string, int> &atual = escopos.back();
    std::map<std::string, int>::iterator existente = atual.find(nome);

    if (existente != atual.end()) {
        erro_semantico(linha, "variavel '%s' ja declarada neste escopo (linha %d)",
                       nome.c_str(), variaveis[existente->second].linha_declaracao);
        return;
    }

    Variavel v;
    v.nome             = nome;
    v.tipo             = tipo;
    v.linha_declaracao = linha;
    v.escopo           = (int) escopos.size() - 1;
    v.usos             = 0;

    atual[nome] = (int) variaveis.size();
    variaveis.push_back(v);
}

// Procura do escopo mais interno para o mais externo. Devolve o tipo da variavel, ou T_ERRO
// (depois de reportar o erro) se ela nao foi declarada
static Tipo usar_variavel(const std::string &nome, int linha)
{
    int i;

    for (i = (int) escopos.size() - 1; i >= 0; i--) {
        std::map<std::string, int>::iterator achada = escopos[i].find(nome);

        if (achada != escopos[i].end()) {
            variaveis[achada->second].usos++;
            return variaveis[achada->second].tipo;
        }
    }

    erro_semantico(linha, "variavel '%s' nao declarada", nome.c_str());
    return T_ERRO;
}

static void imprimir_tabela_de_simbolos(void)
{
    size_t i;

    printf("\nTABELA DE SIMBOLOS\n");

    if (variaveis.empty()) {
        printf("  (nenhuma variavel declarada)\n");
        return;
    }

    printf("%4s  %-25s  %-6s  %5s  %6s  %5s\n", "#", "IDENTIFICADOR", "TIPO", "LINHA", "ESCOPO", "USOS");
    for (i = 0; i < variaveis.size(); i++) {
        printf("%4d  %-25s  %-6s  %5d  %6d  %5d\n",
               (int) (i + 1),
               variaveis[i].nome.c_str(),
               nome_do_tipo(variaveis[i].tipo),
               variaveis[i].linha_declaracao,
               variaveis[i].escopo,
               variaveis[i].usos);
    }
}

// Regras de tipo 

// Resultado de a <op> b para + - * /. Strings nao participam de aritmetica. int op int = int
// (inclusive na divisao); se algum lado for float, o resultado e float
static Tipo tipo_aritmetico(Tipo a, Tipo b, const char *operador, int linha)
{
    if (a == T_STRING || b == T_STRING) {
        erro_semantico(linha, "operador '%s' nao se aplica a strings", operador);
        return T_ERRO;
    }

    if (a == T_ERRO || b == T_ERRO) {
        return T_ERRO;
    }

    return (a == T_FLOAT || b == T_FLOAT) ? T_FLOAT : T_INT;
}

// Condicao "a <op> b": numero com numero sempre vale; string com string so vale com == e !=
static void checar_condicao(Tipo a, Tipo b, int e_igualdade, int linha)
{
    if (a == T_ERRO || b == T_ERRO) {
        return;
    }

    if (a != T_STRING && b != T_STRING) {
        return;
    }

    if (a == T_STRING && b == T_STRING) {
        if (!e_igualdade) {
            erro_semantico(linha, "strings so podem ser comparadas com == ou !=");
        }
        return;
    }

    erro_semantico(linha, "nao e possivel comparar %s com %s", nome_do_tipo(a), nome_do_tipo(b));
}

// Um valor do tipo "origem" cabe numa variavel do tipo "destino"? (float aceita int)
static int atribuivel(Tipo destino, Tipo origem)
{
    return destino == origem || (destino == T_FLOAT && origem == T_INT);
}

static void checar_atribuicao(Tipo destino, Tipo origem, const std::string &nome, int linha)
{
    if (destino == T_ERRO || origem == T_ERRO) {
        return;
    }

    if (!atribuivel(destino, origem)) {
        erro_semantico(linha, "nao e possivel atribuir %s a variavel '%s' do tipo %s",
                       nome_do_tipo(origem), nome.c_str(), nome_do_tipo(destino));
    }
}

// Tipo do ternario a partir dos tipos dos dois ramos
static Tipo unir_ramos(Tipo a, Tipo b, int linha)
{
    if (a == T_ERRO || b == T_ERRO) {
        return T_ERRO;
    }

    if (a == b) {
        return a;
    }

    if (a != T_STRING && b != T_STRING) {
        return T_FLOAT; // int e float
    }

    erro_semantico(linha, "os ramos do ternario tem tipos incompativeis (%s e %s)",
                   nome_do_tipo(a), nome_do_tipo(b));
    return T_ERRO;
}

// Cada valor de um case precisa ter o mesmo tipo da expressao do route em que esta
static void checar_valor_de_case(Tipo valor, int linha)
{
    Tipo esperado;

    if (pilha_de_routes.empty()) {
        return;
    }

    esperado = pilha_de_routes.back();

    if (esperado == T_ERRO || valor == T_ERRO) {
        return;
    }

    if (valor != esperado) {
        erro_semantico(linha, "valor de case do tipo %s, mas o route e sobre %s",
                       nome_do_tipo(valor), nome_do_tipo(esperado));
    }
}

//  Declaracoes 

static void declarar_todas(Tipo tipo, const std::vector<Identificador> &ids)
{
    size_t i;

    for (i = 0; i < ids.size(); i++) {
        declarar(ids[i].nome, tipo, ids[i].linha);
    }
}

// "tipo a, b = x, y;": os valores sao avaliados (e tem seus IDs checados) ANTES desta funcao,
// entao "int a = a;" acusa "a" como nao declarada. Os pares (variavel, valor) sao casados por posicao
static void declarar_com_valores(Tipo tipo, const std::vector<Identificador> &ids,
                                 const std::vector<Tipo> &valores, int linha)
{
    size_t i;

    if (ids.size() != valores.size()) {
        erro_semantico(linha, "a declaracao tem %d variavel(is), mas %d valor(es)",
                       (int) ids.size(), (int) valores.size());
    }

    for (i = 0; i < ids.size() && i < valores.size(); i++) {
        checar_atribuicao(tipo, valores[i], ids[i].nome, linha);
    }

    declarar_todas(tipo, ids);
}
}

%union {
    std::string                *nome;    // lexema de um ID (alocado pelo lexer, liberado pelo parser)
    Tipo                        tipo;
    int                         inteiro;
    std::vector<Identificador> *ids;
    std::vector<Tipo>          *tipos;
}

    /* Libera valores alocados que o parser descarta ao abortar por erro de sintaxe */
%destructor { delete $$; } <nome> <ids> <tipos>

    /* Tokens (terminais), com os mesmos nomes impressos pelo lexer. O texto entre aspas é so um
     * apelido para as mensagens de erro. */
%token <tipo> TIPO
%token <nome> ID
%token LITERAL_INT LITERAL_FLOAT LITERAL_STRING
%token IF "if" ELSE "else" ROUTE "route" TO "to" FALL "fall"
%token VIRGULA "," PONTO_VIRGULA ";" DOIS_PONTOS ":" ATRIBUICAO "=" SETA "->"
%token ABRE_PARENTESES "(" FECHA_PARENTESES ")" ABRE_CHAVES "{" FECHA_CHAVES "}"
%token MAIS "+" MENOS "-" VEZES "*" DIVIDIDO "/"
%token MENOR "<" MENOR_IGUAL "<=" MAIOR ">" MAIOR_IGUAL ">=" IGUAL "==" DIFERENTE "!="

    /* Tipos dos atributos dos nao-terminais */
%type <tipo>    literal fator termo expressao valor ternario ramo_ternario instrucoes_ternario
%type <ids>     lista_ids
%type <tipos>   lista_expressoes
%type <inteiro> operador_relacional

%%

programa
    : lista_instrucoes
    ;

lista_instrucoes
    : %empty
    | lista_instrucoes instrucao
    ;

instrucao
    : declaracao
    | atribuicao
    | if
    | route
    | fall
    ;

    /* Declaracoes. O tipo vem do token TIPO ($1) e e aplicado a todos os ids da lista. Os valores
     * (se houver) ja foram analisados quando a regra e reduzida, so entao as variaveis sao declaradas */

declaracao
    : TIPO lista_ids PONTO_VIRGULA
        {
            declarar_todas($1, *$2);
            delete $2;
        }
    | TIPO lista_ids ATRIBUICAO lista_expressoes PONTO_VIRGULA
        {
            declarar_com_valores($1, *$2, *$4, @3.first_line);
            delete $2;
            delete $4;
        }
    ;

lista_ids
    : ID
        {
            $$ = new std::vector<Identificador>();
            $$->push_back(novo_identificador(*$1, @1.first_line));
            delete $1;
        }
    | lista_ids VIRGULA ID
        {
            $1->push_back(novo_identificador(*$3, @3.first_line));
            $$ = $1;
            delete $3;
        }
    ;

lista_expressoes
    : valor
        {
            $$ = new std::vector<Tipo>();
            $$->push_back($1);
        }
    | lista_expressoes VIRGULA valor
        {
            $1->push_back($3);
            $$ = $1;
        }
    ;

valor
    : expressao { $$ = $1; }
    | ternario  { $$ = $1; }
    ;

    /* if/else e ternario. Os dois comecam com IF "(" condicao ")", mas nunca aparecem no mesmo
     * lugar: o if e uma instrucao e o ternario so aparece como valor (depois de um "=") */

if
    : IF ABRE_PARENTESES expressao_de_condicao FECHA_PARENTESES bloco else_opcional
    ;

else_opcional
    : %empty
    | ELSE bloco
    ;

    /* Cada bloco abre um escopo novo, fechado ao reduzir a regra */
bloco
    : ABRE_CHAVES { entrar_escopo(); } lista_instrucoes FECHA_CHAVES
        { sair_escopo(); }
    ;

    /* O tipo do ternario vem dos tipos dos dois ramos. Cada ramo tem escopo proprio: o que e
     * declarado dentro dele nao existe fora (nem no outro ramo) */
ternario
    : IF ABRE_PARENTESES expressao_de_condicao FECHA_PARENTESES ramo_ternario ELSE ramo_ternario
        { $$ = unir_ramos($5, $7, @1.first_line); }
    ;

ramo_ternario
    : SETA { entrar_escopo(); } instrucoes_ternario
        {
            sair_escopo();
            $$ = $3;
        }
    ;

instrucoes_ternario
    : lista_declaracoes_e_atribuicoes expressao { $$ = $2; }
    | lista_declaracoes_e_atribuicoes ternario  { $$ = $2; }
    ;

lista_declaracoes_e_atribuicoes
    : %empty
    | lista_declaracoes_e_atribuicoes declaracao
    | lista_declaracoes_e_atribuicoes atribuicao
    ;

    /* route/fall. O tipo da expressao do route e empilhado (informacao que "desce" para os cases);
     * cada valor de case e comparado com o topo da pilha. Float nao e aceito no route */

route
    : ROUTE expressao TO
        {
            Tipo tipo_do_route = $2;

            if (tipo_do_route == T_FLOAT) {
                erro_semantico(@1.first_line, "route nao aceita expressao do tipo float (use int ou string)");
                tipo_do_route = T_ERRO;
            }

            pilha_de_routes.push_back(tipo_do_route);
        }
      cases
        { pilha_de_routes.pop_back(); }
    ;

cases
    : ABRE_CHAVES lista_cases FECHA_CHAVES else_opcional
    ;

lista_cases
    : %empty
    | lista_cases case
    ;

    /* Enquanto estamos dentro do bloco de um case, "fall" e valido (inclusive dentro de ifs
     * aninhados nesse bloco) */
case
    : lista_valores_case DOIS_PONTOS { profundidade_de_cases++; } bloco
        { profundidade_de_cases--; }
    ;

lista_valores_case
    : valor_case
    | lista_valores_case VIRGULA valor_case
    ;

valor_case
    : literal
        { checar_valor_de_case($1, @1.first_line); }
    | ID
        {
            Tipo tipo_do_id = usar_variavel(*$1, @1.first_line);
            checar_valor_de_case(tipo_do_id, @1.first_line);
            delete $1;
        }
    ;

fall
    : FALL PONTO_VIRGULA
        {
            if (profundidade_de_cases == 0) {
                erro_semantico(@1.first_line, "'fall' so pode ser usado dentro de um case de um route");
            }
        }
    ;

    /* Atribuicao: a variavel precisa existir e o valor precisa caber no tipo dela */

atribuicao
    : ID ATRIBUICAO valor PONTO_VIRGULA
        {
            Tipo destino = usar_variavel(*$1, @1.first_line);
            checar_atribuicao(destino, $3, *$1, @2.first_line);
            delete $1;
        }
    ;

    /* Expressoes. A precedencia vem da propria estrutura da gramatica: "*" e "/" ficam num nivel
     * mais baixo (termo) que "+" e "-" (expressao), entao sao agrupados primeiro. A recursao a
     * esquerda (expressao: expressao MAIS termo) faz os operadores associarem a esquerda. Em cada
     * regra, o tipo do resultado e calculado a partir do tipo dos filhos (atributo sintetizado) */

expressao_de_condicao
    : expressao operador_relacional expressao
        { checar_condicao($1, $3, $2, @2.first_line); }
    ;

operador_relacional
    : MENOR          { $$ = 0; }
    | MENOR_IGUAL    { $$ = 0; }
    | MAIOR          { $$ = 0; }
    | MAIOR_IGUAL    { $$ = 0; }
    | IGUAL          { $$ = 1; }
    | DIFERENTE      { $$ = 1; }
    ;

expressao
    : termo                   { $$ = $1; }
    | expressao MAIS termo    { $$ = tipo_aritmetico($1, $3, "+", @2.first_line); }
    | expressao MENOS termo   { $$ = tipo_aritmetico($1, $3, "-", @2.first_line); }
    ;

termo
    : fator                   { $$ = $1; }
    | termo VEZES fator       { $$ = tipo_aritmetico($1, $3, "*", @2.first_line); }
    | termo DIVIDIDO fator    { $$ = tipo_aritmetico($1, $3, "/", @2.first_line); }
    ;

fator
    : literal
        { $$ = $1; }
    | ID
        {
            $$ = usar_variavel(*$1, @1.first_line);
            delete $1;
        }
    | ABRE_PARENTESES expressao FECHA_PARENTESES
        { $$ = $2; }
    ;

literal
    : LITERAL_INT     { $$ = T_INT; }
    | LITERAL_FLOAT   { $$ = T_FLOAT; }
    | LITERAL_STRING  { $$ = T_STRING; }
    ;

%%

void yyerror(const char *mensagem)
{
    printf("[%s] ERRO SINTATICO na linha %d: %s\n", NOME_DA_LINGUAGEM, yylineno, mensagem);
}

int main(void)
{
    int resultado = yyparse(); // 0 = programa aceito, 1 = erro de sintaxe (ja reportado pelo yyerror)

    if (resultado != 0) {
        return 1;
    }

    // A estrutura esta correta; erros lexicos (caracteres descartados) e semanticos ja foram impressos
    imprimir_tabela_de_simbolos();

    if (total_de_erros_lexicos > 0 || total_de_erros_semanticos > 0) {
        printf("\n[%s] Estrutura sintaticamente correta, mas com %d erro(s) lexico(s) e %d erro(s) semantico(s)\n",
               NOME_DA_LINGUAGEM, total_de_erros_lexicos, total_de_erros_semanticos);
        return 1;
    }

    printf("\n[%s] Programa sintatica e semanticamente correto\n", NOME_DA_LINGUAGEM);
    return 0;
}
