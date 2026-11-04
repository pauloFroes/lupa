# Lupa

**O software que o Paulo Fróes usa para gravar a tela, dar zoom e fazer marcações nas aulas e apresentações.**

A Lupa fica na barra de menus do Mac, sem ícone no Dock, e entra em ação com um atalho: aproxima qualquer ponto da tela, deixa você desenhar e escrever por cima, segura a sala com um cronômetro de intervalo e grava tudo em alta qualidade, com voz, som do sistema e câmera. A ideia vem do ZoomIt, da Sysinternals, refeita para o macOS.

- **Zoom** em torno do cursor, congelado ou ao vivo, que acompanha o mouse enquanto você usa os apps.
- **Marcações** com caneta, marca-texto, setas, formas, texto e quadro branco ou preto.
- **Gravação** na resolução Retina, até 60 fps, em HEVC, H.264 ou ProRes, com microfone e som do sistema em faixas separadas.
- **Intervalo** com cronômetro em tela cheia para pausar a aula sem perder a turma.

## O que ela faz

| Atalho | Modo | Como usar |
| --- | --- | --- |
| `⌃1` | Zoom | Congela a tela e aproxima em torno do cursor. Role ou use `↑` `↓` para mudar o zoom; mova o mouse para navegar. Clique para desenhar ali mesmo; `esc` sai. |
| `⌃2` | Desenhar | Desenha sobre a tela congelada (ou sobre o zoom, se você veio do `⌃1`). |
| `⌃3` | Intervalo | Cronômetro em tela cheia. `↑` `↓` somam ou tiram 1 minuto, `espaço` pausa, `esc` volta à apresentação. |
| `⌃4` | Zoom ao vivo | Zoom que acompanha o cursor enquanto você usa os apps; o clique vai para o app embaixo. `⌃=` e `⌃-` mudam o zoom. |
| `⌃5` | Gravar tela | Abre o painel de gravação; com a gravação rodando, o mesmo atalho para. |

### No desenho

- **Cores:** `R` vermelho, `G` verde, `B` azul, `O` laranja, `Y` amarelo, `P` rosa. Com `⇧`, a cor vira marca-texto.
- **Formas, segurando a tecla enquanto arrasta:** `⇧` linha, `⌃` (ou `⌘`) retângulo, `⌥` elipse, `⌃⇧` seta.
- **Texto:** `T` escreve onde está o cursor (acentos funcionam); `esc` termina o texto.
- **Espessura:** role o mouse (no texto, muda o tamanho da letra).
- **Quadro:** `W` branco, `K` preto, `E` apaga tudo, `⌘Z` desfaz.
- **Guardar:** `⌘C` copia a imagem; `⌘S` salva um PNG na Mesa.
- Clique direito volta do desenho para o zoom; `esc` sai de tudo.

### Na gravação

O painel do `⌃5` escolhe tela inteira ou uma área (arraste para marcar), som do sistema, microfone (em faixa separada), câmera numa bolha que você arrasta, anel nos cliques, qualidade e 30 ou 60 quadros por segundo. Depois de uma contagem de 3 segundos, a Lupa grava na resolução Retina da tela; o ícone da barra de menus vira um ponto vermelho com o tempo corrido, e o menu pausa, retoma e para.

- **Qualidade:** Alta (HEVC), Compatível (H.264) ou Máxima (ProRes 422, arquivos grandes, para editar).
- **Arquivo:** `.mov` em `Filmes › Lupa`, com quadros constantes (a tela parada não encurta o vídeo) e o som do sistema e o microfone em faixas separadas.
- Zoom, desenho e zoom ao vivo entram no vídeo: dá para aproximar e anotar enquanto grava.
- Ainda não há editor de linha do tempo; para cortar o começo e o fim, abra o arquivo no QuickTime Player (`⌘T`).

Os atalhos mudam em **Ajustes…** (`⌘,` com o menu aberto), junto com o zoom inicial, a cor inicial da caneta e a duração do intervalo.

> `⌃1` a `⌃5` coincidem com "Ir para a Mesa 1…5" do Controle de Missão quando esses atalhos estão ligados em Ajustes do Sistema › Teclado › Atalhos de Teclado. Se você usa essas mesas, troque os atalhos da Lupa em Ajustes.

## Instalar a partir do código

Precisa do macOS 15 ou mais novo e das Command Line Tools do Xcode (`xcode-select --install`).

```bash
git clone https://github.com/pauloFroes/lupa.git
cd lupa
scripts/build-app.sh --install --open
```

O script compila em modo release, monta `build/Lupa.app` com ícone e fontes, assina e, com `--install`, copia para `/Applications`. Para abrir junto com o Mac, ligue **Abrir ao iniciar sessão** no menu.

## Permissões

Na primeira vez, o macOS pede três permissões em Ajustes do Sistema › Privacidade e Segurança:

- **Gravação de Tela e Áudio do Sistema**, obrigatória: o zoom e o desenho trabalham sobre uma foto da tela tirada na hora do atalho, e a gravação filma a tela. Nada sai do seu Mac.
- **Microfone** e **Câmera**, só se você ligar essas opções no painel de gravação.

Depois de permitir a Gravação de Tela, abra a Lupa de novo.

A assinatura é ad-hoc (sem certificado de desenvolvedor), e o macOS amarra a permissão à assinatura. Por isso **cada nova compilação volta a pedir a permissão**. Se ela ficar presa, zere e permita de novo:

```bash
tccutil reset ScreenCapture io.github.paulofroes.lupa
```

Com um certificado próprio, exporte `LUPA_SIGN_IDENTITY="Apple Development: …"` antes do script, e a permissão sobrevive às compilações.

## Por dentro

Swift e AppKit, empacotado pelo Swift Package Manager, sem Xcode. A captura usa o ScreenCaptureKit; a gravação escreve com o AVAssetWriter. Os atalhos globais usam o `RegisterEventHotKey` do Carbon, que dispensa a permissão de Acessibilidade. O visual segue o Eduliv Design System: tinta, papel e o lime como único acento, com Bricolage Grotesque, Manrope e JetBrains Mono.

| Pasta | O que tem |
| --- | --- |
| `Sources/Lupa/` | App, zoom e desenho, intervalo, zoom ao vivo, atalhos e ajustes |
| `Sources/Lupa/Recording/` | Gravador, painel, seleção de área, contagem e bolha da câmera |
| `Resources/` | `Info.plist` e as fontes |
| `scripts/` | `build-app.sh` e o gerador do ícone |

## Licença

Código sob a licença MIT (`LICENSE`). As fontes Bricolage Grotesque, Manrope e JetBrains Mono são distribuídas sob a SIL Open Font License; os textos estão em `Resources/Fonts/`.
