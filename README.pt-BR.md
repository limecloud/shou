<h1 align="center"><img src="assets/brand/shou-icon-1024.png" width="48" alt="Shou" /> Shou · 收拾一下</h1>

<p align="center"><strong>Um pouco mais de espaço no seu Mac.</strong><br />Tidy up. That's it.</p>

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · [Português (Brasil)](README.pt-BR.md) · [Русский](README.ru.md) · [Українська](README.uk.md)

<p align="center">
  <a href="https://github.com/limecloud/shou/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/limecloud/shou?display_name=tag&amp;sort=semver" /></a>
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-111827?logo=apple&amp;logoColor=white" />
  <img alt="Apple Silicon and Intel" src="https://img.shields.io/badge/Apple_Silicon_%26_Intel-universal-555" />
  <a href="LICENSE"><img alt="Apache-2.0" src="https://img.shields.io/badge/license-Apache--2.0-blue" /></a>
</p>

Um limpador nativo do macOS para caches, projetos de desenvolvimento e pastas que crescem. Veja o uso do espaço, revise a seleção e reutilize suas regras.

## Download e instalação

Shou v0.1.0 requer **macOS 14 ou posterior**. O app universal funciona em Apple Silicon e Intel. Arraste **Shou.app** da imagem de disco para **Applications**. A interface está em inglês e chinês simplificado.

[**Shou v0.1.0 · macOS (.dmg)**](https://github.com/limecloud/shou/releases/download/v0.1.0/Shou-0.1.0-macos-universal.dmg) · [.zip](https://github.com/limecloud/shou/releases/download/v0.1.0/Shou-0.1.0-macos-universal.zip) · [CLI](https://github.com/limecloud/shou/releases/download/v0.1.0/shou-0.1.0-macos-universal.tar.gz) · [Releases](https://github.com/limecloud/shou/releases)

Esta versão tem assinatura ad-hoc e não é notarizada pela Apple. Se a abertura for bloqueada, verifique a origem e consulte **Ajustes do Sistema → Privacidade e Segurança → Abrir Mesmo Assim**.

## O que o Shou faz

| | |
| --- | --- |
| **Caches de aplicativos** | Revise juntos os caches do Chrome, Edge, Firefox, Codex, Claude, QQ, WeChat e outros apps. |
| **Desenvolvimento e projetos** | Encontre caches npm, Cargo, Xcode, Python e Go, Rust target, dependências Node.js e produtos Swift. |
| **Análise de espaço** | Explore pastas com um mapa de árvore e uma lista de diretórios. |
| **Regras pessoais** | Crie regras para pastas regeneráveis, visualize os resultados e reutilize-as. |
| **Histórico e restauração** | Veja resultados, restaure itens ou confirme separadamente a remoção permanente. |
| **Atualizações online** | Busque nos Ajustes ou no menu Shou. A assinatura é verificada antes da instalação. |

## Limpe em três etapas

1. **Analise.** Escolha apps ou adicione um espaço de trabalho. A análise não remove arquivos.
2. **Revise.** Confira caminhos, tamanhos, riscos e requisitos de regeneração.
3. **Confirme.** Mova a seleção para o Lixo e restaure pelo histórico, se necessário.

O Lixo não libera espaço imediatamente. A remoção permanente exige outra confirmação e não pode ser desfeita. Conteúdo protegido, exclusões, apps e compilações ativas podem bloquear a limpeza.

## Seus arquivos, sua escolha

As regras são locais e não executam comandos Shell. Nenhuma conta, conexão a modelos ou análise na nuvem é necessária. Regras e histórico ficam no Mac.

## Use pelo terminal

A CLI independente gerencia regras, análises, planos e histórico. Limpeza e restauração exigem confirmação interativa.

```sh
/Applications/Shou.app/Contents/Helpers/shou --help
/Applications/Shou.app/Contents/Helpers/shou capabilities --json
/Applications/Shou.app/Contents/Helpers/shou system scan --json
```

## Documentação e contribuições

Consulte a documentação para compilar, testar e usar regras ou a CLI. Envie problemas e sugestões pelo Issues.

[Documentation](docs/README.md) · [Development](docs/engineering/development.md) · [Rules](docs/rules/rule-specification.md) · [CLI](docs/ai/agent-and-cli-contract.md) · [Issues](https://github.com/limecloud/shou/issues)

## Agradecimentos

[MangoDisk](https://github.com/harry0703/MangoDisk) · [Mole](https://github.com/tw93/mole) · [Pulse](https://pulse.egoist.dev/) · [BuhoCleaner](https://www.drbuho.com/buhocleaner) · [Sparkle](https://sparkle-project.org/)

## Licença

[Apache License 2.0](LICENSE).
