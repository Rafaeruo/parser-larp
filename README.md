# Parser LARP

Analisador lexico e sintatico para LARP, uma linguagem em estilo C com declaracoes,
atribuicoes, `if`/`else`, ternario (`if (...) -> ... else -> ...`) e `route`/`fall`.

O projeto tem duas partes:

- **Lexer** (`clarker.l`, Flex): quebra o codigo-fonte em tokens e reporta erros lexicos.
- **Parser** (`parser.y`, Bison): consome os tokens do lexer, verifica a estrutura do
  programa e faz a analise semantica (tipos, escopos, declaracoes).

O parser é gerado em `bin/parser`, que usa o lexer internamente. O `bin/lexer`
continua disponivel sozinho para inspecionar os tokens de um programa.

## Parser

Recebe os tokens do lexer e verifica a estrutura do programa segundo a gramatica em
`gramatica_ebnf.txt`. Ao primeiro erro sintatico, imprime a linha e para. Se a estrutura
estiver correta, reporta os erros semanticos encontrados (variavel nao declarada ou
redeclarada no mesmo escopo, tipos incompativeis em atribuicoes, comparacoes, ternarios e
cases de `route`, `fall` fora de um case, etc.) e imprime a tabela de simbolos.

## Lexer

Tokens reconhecidos:

| Categoria              | Tokens                                                                              |
|------------------------|-------------------------------------------------------------------------------------|
| Tipos                  | `TIPO` (`string`, `int`, `float`)                                                   |
| Palavras reservadas    | `IF`, `ELSE`, `ROUTE`, `TO`, `FALL`                                                 |
| Identificadores        | `ID`                                                                                |
| Literais               | `LITERAL_INT`, `LITERAL_FLOAT`, `LITERAL_STRING` (escapes `\"`, `\\`, `\n`, `\t`)   |
| Pontuacao              | `VIRGULA`, `PONTO_VIRGULA`, `DOIS_PONTOS`, `ATRIBUICAO` (`=`), `SETA` (`->`), `ABRE_PARENTESES`, `FECHA_PARENTESES`, `ABRE_CHAVES`, `FECHA_CHAVES` |
| Operadores aritmeticos | `MAIS`, `MENOS`, `VEZES`, `DIVIDIDO`                                                |
| Operadores relacionais | `MENOR`, `MENOR_IGUAL`, `MAIOR`, `MAIOR_IGUAL`, `IGUAL` (`==`), `DIFERENTE` (`!=`)  |

Espacos em branco sao ignorados. Todo erro lexico e reportado com o numero da linha:
caractere que nao pertence a nenhum token (`NAO RECONHECIDO`), string com escape ou
caractere invalido (`STRING INVALIDA`) e string sem aspas de fechamento
(`STRING NAO TERMINADA`). Rodando sozinho (`bin/lexer`), ao final imprime a tabela de
simbolos e um resumo.

## Executar no Colab

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)](https://colab.research.google.com/github/Rafaeruo/parser-larp/blob/master/colab.ipynb)

## Executar localmente

Requer `flex`, `bison`, `g++` e `make`.

```bash
make                                                           # compila bin/lexer e bin/parser
make run FILE=test-programs/01-declaracoes-simples.larp        # roda o parser (lexer + parser) em um arquivo
make run-lexer FILE=test-programs/01-declaracoes-simples.larp  # roda so o lexer em um arquivo
make test                                                      # roda o parser em todos os test-programs/*.larp
make test-lexer                                                # roda so o lexer em todos os test-programs/*.larp
make clean                                                     # remove bin/
```

Os dois leem da entrada padrao. Tambem podem ser executados diretamente assim:
`./bin/lexer < test-programs/01-declaracoes-simples.larp` ou
`./bin/parser < test-programs/01-declaracoes-simples.larp`.

## Programas de teste

Todos os testes ficam na mesma pasta e podem ser executados tanto pelo lexer quanto pelo
parser (`make test-lexer` e `make test`). A dezena do numero indica a fase que o teste
pretende exercitar:

| Faixa | Categoria         | Lexer (`bin/lexer`)                  | Parser (`bin/parser`)                                   |
|-------|-------------------|--------------------------------------|---------------------------------------------------------|
| `0x`  | validos           | todos os tokens, 0 erros             | `Programa sintatica e semanticamente correto`           |
| `1x`  | erros lexicos     | todos os erros lexicos, com a linha  | erros lexicos ate o primeiro erro sintatico (cascatas)  |
| `2x`  | erros sintaticos  | 0 erros (o programa e lexicamente valido) | um erro sintatico, com a linha                     |

### Validos

| Arquivo                          | O que testa                                                               |
|----------------------------------|---------------------------------------------------------------------------|
| `01-declaracoes-simples`         | declaracoes individuais e em lista                                        |
| `02-identificadores`             | formatos de identificador (`_`, digitos, maiusculas, nome longo)          |
| `03-prefixos-de-reservadas`      | identificadores que comecam com palavras reservadas (`iffy`, `router`...) |
| `04-espacos-e-quebras`           | espacos, tabs e quebras de linha no meio das declaracoes                  |
| `05-inicializacao`               | declaracoes com valor inicial, incluindo em lista                         |
| `06-if-else`                     | `if`/`else` aninhados, os seis operadores relacionais e aritmetica        |
| `07-ternario`                    | ternario em declaracao e atribuicao, aninhado e com instrucoes nos ramos  |
| `08-route-fall`                  | `route` com cases de int, string, ID e varios valores, `fall` e `else`    |
| `09-literais`                    | inteiros, floats e strings com todos os escapes e simbolos imprimiveis    |

### Erros lexicos

| Arquivo                          | O que testa                                                               |
|----------------------------------|---------------------------------------------------------------------------|
| `11-caracteres-invalidos`        | caracteres fora da linguagem (`@`, `$`, `&&`, `!`, `'`)                   |
| `12-numeros-malformados`         | `3.`, `.5`, `1.2.3`, `1..2`                                               |
| `13-strings-invalidas`           | escape invalido, tab, acento, strings nao terminadas                      |

### Erros sintaticos

| Arquivo                          | O que testa                                                               |
|----------------------------------|---------------------------------------------------------------------------|
| `21-tipo-inexistente`            | `double z;`: `double` nao e tipo, chega ao parser como `ID`               |
| `22-declaracao-sem-virgula`      | `int a b;`: falta a virgula entre os identificadores                      |
| `23-lista-incompleta`            | `float x,;`: lista de identificadores terminada em virgula                |
| `24-identificador-com-digito`    | `int 2contador;`: chega ao parser como `LITERAL_INT` seguido de `ID`      |
| `25-if-sem-parenteses`           | `if a < b { ... }`: condicao sem parenteses                               |
| `26-inicializacao-sem-valor`     | `int c = ;`: `=` sem valor                                                |
| `27-route-sem-to`                | `route x { ... }`: falta o `to`                                           |
| `28-fim-inesperado`              | `int` no fim do arquivo: declaracao interrompida                          |

## Estrutura

    clarker.l          lexer
    parser.y           parser
    Makefile           comandos de build e execucao
    test-programs/     programas de teste (.larp)
    colab.ipynb        notebook para executar no Google Colab
    gramatica_ebnf.txt gramática em sintaxe EBNF, base usada para fazer o parser.y
