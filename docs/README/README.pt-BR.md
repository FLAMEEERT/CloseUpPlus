# CloseUpPlus

[English](../../README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [Français](README.fr.md) · [Deutsch](README.de.md) · [Español](README.es.md) · **Português** · [Русский](README.ru.md)

**Devolva os controles ao Mission Control.** O CloseUpPlus sobrepõe controles de janela
ao Mission Control nativo do macOS — feche, minimize, maximize, oculte ou encerre qualquer
janela sem sair da visão geral — e adiciona controle total pelo teclado.
Gratuito, nativo e de código aberto.

## Capturas de tela

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/overlay-dark.png">
    <img alt="Controles de janela sobre uma miniatura do Mission Control" src="../images/overlay-light.png" width="48%">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/settings-general-en-dark.png">
    <img alt="Configurações gerais" src="../images/settings-general-en-light.png" width="49%">
  </picture>
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../images/settings-shortcuts-en-dark.png">
    <img alt="Atalhos de teclado" src="../images/settings-shortcuts-en-light.png" width="49%">
  </picture>
</p>

## Recursos

- **Feche pela visão geral** — passe o ponteiro sobre a miniatura de uma janela no Mission Control e
  clique no × vermelho para fechá-la instantaneamente, sem precisar alternar para ela antes.
- **Todas as ações de janela** — minimize, maximize, oculte o app ou encerre o app. Fechar,
  minimizar e maximizar são botões opcionais que você pode ativar ou desativar nos Ajustes;
  ocultar e encerrar aparecem sempre que a janela permitir.
- **Controle pelo teclado** — atue sobre a janela sob o ponteiro com ações nativas:
  ⌘W fechar, ⌘M minimizar, ⌘F maximizar, ⌘H ocultar, ⌘Q encerrar — todas remapeáveis.
- **Ações em lote** — ⌥⌘W fechar tudo, ⌥⌘M minimizar tudo, ⌥⌘H ocultar todas exceto a
  que está sob o ponteiro.
- **Nove idiomas** — English, 简体中文, 繁體中文, 日本語, Français, Deutsch,
  Español, Português, Русский, alternáveis no app e aplicados em tempo real.
- **Nativo e discreto** — uma sobreposição passiva que nunca interfere no próprio gerenciamento de teclado
  do Mission Control; apenas na barra de menus, sem ícone no Dock.
- **Pin interativo** — fixe uma janela pelo Mission Control e interaja com a janela real ao mover o ponteiro sobre ela.

## Como o CloseUpPlus se compara

O CloseUpPlus se concentra em uma única coisa — atuar sobre as janelas diretamente na visão
**nativa** do Mission Control. Veja como ele se compara às alternativas mais próximas que
fazem o mesmo (verificado em 02/07/2026 no site/repositório oficial de cada projeto — veja os
links para as fontes; campos que o fornecedor não documenta são marcados como "Não documentado"
em vez de estimados):

| | CloseUpPlus | [Mission Control Close](https://missioncontrolclose.com/) | [Open Mission Control](https://github.com/nohackjustnoobb/OpenMissionControl) | [Mission Control Plus](https://www.fadel.io/missioncontrolplus) |
|---|---|---|---|---|
| Preço | Gratuito | £5 vitalício (teste de 7 dias) | Gratuito | Pago, preço não publicado (teste de 10 dias) |
| Licença | Código aberto (GPL-3.0) | Código fechado | Código aberto (GPL-3.0) | Código fechado |
| Ações na janela sob o cursor | Fechar, minimizar, maximizar, ocultar, encerrar | Somente fechar | Fechar, minimizar, maximizar | Fechar, minimizar, encerrar (+ abrir) |
| Ações em lote | Fechar todas, minimizar todas, ocultar todas exceto uma | Fechar todas | Não documentado | Não documentado |
| Atalhos de teclado remapeáveis | Todas as ações | Tem atalhos; remapeamento não documentado | Fixos (⌘Q/⌘W/⌘M/⌘F) | Fixos (⌘W/⌘M/⌘Q/⏎) |
| Localização | 9 idiomas, alternáveis no app | Não documentado | Não documentado | Não documentado |
| macOS necessário | 14.0+ | 26.0 (Tahoe)+ | Não documentado | 10.13+ |
| Arquitetura de CPU | Apple Silicon e Intel, builds separados | Somente Apple Silicon | Não documentado | Não documentado |
| Distribuição | GitHub Releases (assinatura ad hoc, sem notarização da Apple) | Download direto, checkout via LemonSqueezy | GitHub + Homebrew (não assinado — é preciso remover a quarentena manualmente) | Download direto |

Outras ferramentas de gerenciamento de janelas do macOS — [AltTab](https://github.com/lwouis/alt-tab-macos), [DockDoor](https://github.com/ejbills/DockDoor), [HyperDock](https://bahoom.com/hyperdock), [Contexts](https://contexts.co/) — oferecem ações de janela relacionadas (fechar, ocultar, alternar), mas por meio de seu próprio alternador ou interface de hover no Dock, e não da visão nativa do Mission Control — por isso resolvem um problema relacionado, porém diferente, e não entram na comparação acima.

## Requisitos

- macOS 14.0 ou posterior
- Apple Silicon (arm64) ou Intel (x86_64) — o CloseUpPlus distribui um build
  separado para cada arquitetura; baixe o que corresponde ao seu Mac
- Permissão de Acessibilidade (o CloseUpPlus lê e atua sobre as janelas por meio da
  API de Acessibilidade)
- Permissão de gravação de tela apenas para Pin; a janela selecionada fica local
  e não é salva nem enviada

## Instalação

Baixe a versão correspondente ao chip do seu Mac em
[Releases](https://github.com/FLAMEEERT/CloseUpPlus/releases) — `CloseUpPlus-*-arm64.dmg`
para Apple Silicon, `CloseUpPlus-*-x86_64.dmg` para Intel —, abra-o e arraste o
CloseUpPlus para a pasta Aplicativos. Este build não é notarizado pela Apple:
na primeira abertura, clique com o botão direito no app e escolha **Abrir**, ou
autorize-o em Ajustes do Sistema → Privacidade e Segurança.

Na primeira execução, conceda acesso de Acessibilidade em Ajustes do Sistema →
Privacidade e Segurança → Acessibilidade — o CloseUpPlus abre o painel correto para você.

## Uso

Abra o Mission Control normalmente (deslize para cima com três/quatro dedos ou use a tecla Mission
Control). Passe o ponteiro sobre qualquer janela para revelar seu conjunto de controles ou use o
teclado:

| Ação | Atalho | Atua sobre |
|---|---|---|
| Fechar janela | ⌘W | janela sob o ponteiro |
| Minimizar janela | ⌘M | janela sob o ponteiro |
| Maximizar janela | ⌘F | janela sob o ponteiro |
| Ocultar app | ⌘H | janela sob o ponteiro |
| Encerrar app | ⌘Q | janela sob o ponteiro |
| Fechar todas as janelas | ⌥⌘W | todas as janelas |
| Minimizar todas as janelas | ⌥⌘M | todas as janelas |
| Ocultar todas exceto esta | ⌥⌘H | todos os apps exceto o que está sob o ponteiro |

Todos os atalhos são remapeáveis em Ajustes → Atalhos. Ative ou desative o CloseUpPlus a
qualquer momento pelo ícone da barra de menus ou em Ajustes → Geral.

## Ajustes

- **Geral** — ativar/desativar, abrir ao iniciar a sessão, ocultar o ícone da barra de
  menus, status da Acessibilidade com concessão em um clique, quais botões de controle
  aparecem, e o idioma do app.
- **Atalhos** — remapeie cada ação.
- **Sobre** — versão, licença, link para o repositório no GitHub, e agradecimentos.

## Compilar a partir do código-fonte

```bash
brew install xcodegen
make build      # Compilação Debug (uma identidade distinta "CloseUp Dev")
make dev-cert   # opcional: identidade de assinatura local estável para que a
                # permissão de Acessibilidade sobreviva a recompilações
make test       # testes unitários + verificações de i18n
make run        # compilar e executar
make dmg        # empacotar um .dmg de arrastar para instalar
```

O projeto do Xcode é gerado a partir de `project.yml` pelo XcodeGen e não é versionado
no repositório. Consulte [../DESIGN.md](../DESIGN.md) para a arquitetura e
[../RUNBOOK.md](../RUNBOOK.md) para o processo de lançamento.

## Licença

[GPL-3.0](../../LICENSE).

## Agradecimentos

Obrigado a [OpenMissionControl](https://github.com/nohackjustnoobb/OpenMissionControl),
[DockDoor](https://github.com/ejbills/DockDoor) e
[alt-tab-macos](https://github.com/lwouis/alt-tab-macos): o uso que
o CloseUpPlus faz das APIs privadas do Mission Control se inspira em como esses
projetos as utilizam.
