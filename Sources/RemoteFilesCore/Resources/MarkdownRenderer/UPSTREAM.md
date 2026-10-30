# Bundled Markdown renderer libraries

These unmodified distributions are loaded only into an isolated WebKit content world.
No package manager or network access is used at runtime. KaTeX outputs native MathML, so web fonts are unnecessary.
The exact Mermaid distribution contains trailing whitespace inside bundled strings.
Its path disables only Git's end-of-line whitespace warning in `.gitattributes`
so updating the bundle can preserve upstream bytes and the hash below.

| Library | Version | Distribution SHA-256 |
| --- | --- | --- |
| mermaid | 12.2.0 | `a8a6a6f805b074a8261a2825c86f99c8054acb3b35f50bb7e24a4f9f2c3c3b9f` |
| katex | 0.19.1 | `fa140498b8cfc8302cbe5e7cb1bdbc1f952bc38b3fa258ede09e73edbf9a74bc` |
| marked | 18.1.2 | `9eb730d2362ae1a8c6201698f17009e16671be6946d3d06503ddc0575283db7c` |
| dompurify | 3.4.17 | `cd37898f9782adf54820c413191b5691803f0f137c799d6edcfd38523b4c2c31` |

Sources: https://registry.npmjs.org/{library}/-/{library}-{version}.tgz.
Upstream projects: https://github.com/mermaid-js/mermaid, https://github.com/KaTeX/KaTeX, https://github.com/markedjs/marked, https://github.com/cure53/DOMPurify.

To update: select reviewed releases, extract the distribution and license from each npm tarball, update these hashes, and rerun EnhancedMarkdownTests and hosted EnhancedMarkdownDisplayTests.
The integration and resource limits are in markdown-renderer.js.
