# EstudeVet · site, diagnóstico e CRM

Tudo aqui é arquivo único, HTML puro, sem build e sem dependência. Você sobe a
pasta e funciona. Cada página vive numa pasta com `index.html` dentro, que é o
que faz o endereço ficar limpo: `estudevet.com.br/diagnostico` em vez de
`estudevet.com.br/diagnostico.html`.

A plataforma do aluno não está aqui, você vai subir ela separado.

---

## O que vai para cada endereço

| Endereço | Arquivo | O que é | Público |
|---|---|---|---|
| `estudevet.com.br/` | `index.html` | site com portão de lead e vitrine de produtos | sim |
| `estudevet.com.br/diagnostico` | `diagnostico/index.html` | as 18 perguntas e o laudo | sim |
| `estudevet.com.br/privacidade` | `privacidade/index.html` | política de privacidade | sim |
| `estudevet.com.br/crm` | `crm/index.html` | o seu CRM, exige login de admin | não |
| qualquer outro | `404.html` | página de erro que leva de volta | sim |

A pasta `sql/` fica no repositório só como histórico e para você achar os
arquivos quando precisar. Ela não é servida como página.

---

## Como subir

### Opção 1: Vercel (recomendada)

É a mais simples porque lê o `vercel.json` que já está aqui, com os cabeçalhos
de segurança e o `/crm` fora dos buscadores.

1. Suba esta pasta para um repositório no GitHub
2. Em vercel.com, importe o repositório
3. Em Framework Preset escolha **Other**, e deixe Build Command e Output
   Directory vazios, porque não existe build
4. Em Settings, Domains, adicione `estudevet.com.br` e `www.estudevet.com.br`
5. Na Cloudflare, aponte o DNS conforme a Vercel mandar

Cada `git push` publica sozinho.

### Opção 2: GitHub Pages

1. Suba a pasta para um repositório
2. Settings, Pages, Source: Deploy from a branch, branch `main`, pasta `/`
3. Em Custom domain coloque `estudevet.com.br`, que já existe o arquivo `CNAME`
   aqui com esse conteúdo

O GitHub Pages ignora o `vercel.json`, então os cabeçalhos de segurança não
valem nessa opção. Para o que você tem hoje isso não é problema.

---

## O que conferir antes de considerar no ar

- [ ] Rodou os arquivos de `sql/` na ordem, no projeto `opuaaoccuzkbahuvwamf`
- [ ] Abriu `estudevet.com.br` no celular e o portão apareceu inteiro
- [ ] Preencheu o portão com dados de teste e o lead apareceu na Entrada do CRM
- [ ] Fez o diagnóstico até o fim e o botão do WhatsApp abriu com o laudo escrito
- [ ] Apagou os leads de teste
- [ ] `estudevet.com.br/crm` pede login e não entra sem ele
- [ ] Trocou o e-mail de contato na política de privacidade, se não for
      `contato@estudevet.com.br`
- [ ] Preencheu `CONFIG.PIXEL` no diagnóstico com o ID do seu pixel do Meta
- [ ] Em Authentication, URL Configuration do Supabase, autorizou o domínio

---

## Ordem dos arquivos de SQL

Rode uma vez cada um, no SQL Editor do Supabase. Todos podem ser rodados de
novo sem estragar nada.

| Arquivo | O que cria |
|---|---|
| `01-plataforma.sql` | base de tudo: perfis, produtos, pedidos, `eh_admin()` e `emails_admin()` |
| `02-leads.sql` | `leads` e `lead_eventos`, que é o que o site e o diagnóstico gravam |
| `03-fotos.sql` | `produto_fotos`, as fotos de aplicação da vitrine |
| `04-modo-produto.sql` | a coluna `modo`, que separa produto com pagamento de produto só de vitrine |
| `05-crm.sql` | as sete tabelas `crm_*` e as etiquetas iniciais |
| `06-etiquetas-diagnostico.sql` | as duas etiquetas que faltavam para o diagnóstico |

Em `sql/extras` ficam dois que você roda só quando precisar:
`virar-admin.sql` para promover uma conta, e `consertar-imagens.sql` para
diagnosticar upload de capa que não salva.

**O `01-plataforma.sql` é da plataforma que você vai subir depois, mas rode
ele mesmo assim, agora.** O site lê a tabela `produtos` que nasce nele, e sem
ela a vitrine abre vazia.

---

## Onde ficam as configurações

Cada página tem um bloco `CONFIG` no topo do script, em português, com
comentário em cada linha. As três que você provavelmente vai querer mexer:

| Página | Chave | Para quê |
|---|---|---|
| todas | `WHATSAPP` | o número que recebe tudo, hoje `5574999991455` |
| site | `PORTAO` | `false` tira o formulário da entrada e mostra a vitrine direto |
| site | `MOSTRAR_PRECO` | `false` mantém tudo como a consultar |
| diagnóstico | `PIXEL` | ID do pixel do Meta, vazio deixa desligado |
| diagnóstico e site | `SALVAR_LEAD` | `false` para testar sem gravar nada no banco |

---

## Sobre a chave do Supabase estar no código

Ela está, e pode estar. As tabelas `leads` e `lead_eventos` só aceitam
inserção de visitante e não têm política de leitura, então quem copiar a chave
consegue mandar uma linha e nada mais. `produtos` libera leitura só do que está
publicado. Todo o resto exige login.

O que **não** pode aparecer em lugar nenhum desses arquivos é a chave
`service_role`. Se algum dia você precisar dela, ela vai numa Edge Function, no
servidor, nunca no HTML.

---

## Uma coisa sobre a política de privacidade

Eu escrevi ela com base no que estas páginas realmente coletam, e ela está
honesta e específica, que é o que importa tanto para o Meta quanto para a LGPD.

Só que eu não sou advogado e isso não é parecer jurídico. Antes de rodar
anúncio com volume, vale um advogado dar uma olhada, principalmente na parte de
prazo de guarda e na identificação do controlador, que hoje está como
"Wendell Dev" e deveria trazer a razão social e o CNPJ do seu MEI.

Troque também o e-mail `contato@estudevet.com.br` se ele ainda não existe. Uma
política que dá um endereço morto é pior que não ter política, porque ela vira
prova de que você disse que responderia e não respondeu.

---

## Uma dependência externa, no CRM

O site e o diagnóstico não dependem de nada de fora: eles falam com o Supabase
por requisição direta e o resto é próprio. O CRM é a exceção, porque precisa de
login e para isso carrega a biblioteca oficial do Supabase de um CDN:

```
https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm
```

Funciona e é o endereço oficial. Se um dia você quiser o CRM funcionando mesmo
com o CDN fora do ar, baixe esse arquivo para `assets/supabase.js` e troque o
endereço no `crm/index.html`. Enquanto for só você usando, não vale o trabalho.

---

## Rastreio de anúncio

Toda página lê `?src=` da URL e grava esse código em `leads.origem`. Use um
código por criativo:

```
estudevet.com.br/?src=ma-a1
estudevet.com.br/diagnostico?src=ma-g4
```

Na Entrada do CRM você vê a origem de cada pessoa, sem depender do painel do
Meta. Sem `?src=`, o site grava `site` e o diagnóstico grava `diagnostico`.

---

## Estrutura

```
.
├── index.html                    o site
├── diagnostico/index.html        as 18 perguntas e o laudo
├── privacidade/index.html        política de privacidade
├── crm/index.html                o CRM, privado
├── 404.html
├── assets/                       símbolo, lockup e favicon
├── sql/                          os arquivos do banco, na ordem
├── robots.txt                    mantém /crm fora dos buscadores
├── sitemap.xml
├── vercel.json                   cabeçalhos e endereço limpo
└── CNAME                         domínio, usado pelo GitHub Pages
```
