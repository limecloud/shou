# Shou · 收

**Tidy up. That’s it.**

[English](README.md) · [简体中文](README.zh-CN.md) · [繁體中文](README.zh-TW.md) · [日本語](README.ja.md) · [한국어](README.ko.md) · [Deutsch](README.de.md) · [Français](README.fr.md) · [Español](README.es.md) · Português (Brasil) · [Русский](README.ru.md) · [Українська](README.uk.md)

Uma ferramenta de limpeza nativa para macOS, com regras que podem ser revisadas e reutilizadas em projetos de desenvolvimento e aplicativos.

> **Status: fase de projeto.** O aplicativo e a CLI ainda não estão disponíveis. As funções abaixo estão planejadas. Um README traduzido não significa que o aplicativo já ofereça suporte ao idioma.

## Por que Shou?

Diretórios Rust `target`, dependências de Node.js, caches de projetos e arquivos de compilação podem lotar repetidamente um Mac de 500 GB. A função de um diretório varia conforme o projeto: nome e tamanho não bastam para decidir se ele pode ser removido.

Shou transforma uma decisão de limpeza revisada em uma regra pessoal: **Encontrar → Entender → Definir uma regra → Visualizar → Confirmar → Reutilizar.** Mudanças que o formato de regras existente consegue expressar não exigem uma atualização do aplicativo. Novas capacidades do mecanismo ainda exigem atualização.

## Funções planejadas

- **Análise por projeto:** distinguir arquivos de compilação, dependências instaladas, código-fonte e dados não classificados nos espaços de trabalho selecionados explicitamente.
- **Regras pessoais:** definir caminhos, marcadores de projeto, condições de retenção e exclusões; visualizar os itens afetados e os riscos.
- **Desktop e CLI independentes:** núcleo compartilhado para gerenciar regras, analisar, preparar planos e consultar o histórico por qualquer uma das interfaces.
- **Interfaces para agentes existentes:** Codex, Claude Code, WorkBuddy e ferramentas semelhantes podem adicionar rascunhos de regras desativados por uma CLI estável e JSON. Shou não integra modelos nem desenvolve ou hospeda agentes.
- **Arquitetura nativa:** Swift, SwiftUI e AppKit. Núcleo portável em monorepo; o suporte futuro ao Windows exige implementação e validação próprias.

## Revisar antes de limpar

As regras não ampliam permissões do sistema operacional. Rascunhos precisam de validação e prévia; ativar uma regra não autoriza exclusões. Cada execução exige a confirmação de um plano específico. A CLI não oferece opções para pular essa confirmação.

Por padrão, os itens vão para o Lixo. Remover permanentemente os itens desta operação exige outra confirmação, sem esvaziar os demais conteúdos do Lixo. O volume movido e o espaço realmente disponível são apresentados separadamente. `node_modules` contém dependências que exigem revisão cuidadosa, não caches comuns. Nomes, arquivos de lock e critérios de idade não garantem que os dados possam ser recriados.

## Documentação e contribuições

[English documentation](docs/README.md) · [简体中文技术文档](docs/zh-CN/README.md) · [Internacionalização (inglês)](docs/product/internationalization.md)

O repositório contém documentos de projeto, um contrato provisório de regras e exemplos. Ainda não há aplicativo para download. As [Issues](https://github.com/limecloud/shou/issues) recebem casos concretos sem informações confidenciais e melhorias de tradução.

## Agradecimentos

- [Mole](https://github.com/tw93/mole): fluxos de trabalho de terminal para desenvolvedores e apresentação multilíngue do projeto.
- [Pulse](https://pulse.egoist.dev/): organização nativa de informações no macOS e resumos de espaço em disco.
- [BuhoCleaner](https://www.drbuho.com/buhocleaner): exploração do disco e agrupamento de resultados da limpeza.

Agradecemos pela inspiração de produto e design. Estes agradecimentos não implicam afiliação nem dependência de código.

## Licença

[Apache License 2.0](LICENSE).
