/* App-owned offline Markdown integration. Executed in WKContentWorld.defaultClient only. */
(() => {
  'use strict';
  const tags = ['p','br','hr','h1','h2','h3','h4','h5','h6','blockquote','pre','code','ul','ol','li','strong','b','em','i','s','del','sup','sub','kbd','samp','var','table','thead','tbody','tfoot','tr','th','td','caption','colgroup','col','div','span','details','summary','dl','dt','dd','abbr','mark','a','img'];
  const attributes = ['href','src','alt','title','colspan','rowspan','scope','start','reversed','open','align'];
  let images = [], generation = 0, observer;
  function escape(value) {
    const element = document.createElement('span'); element.textContent = value; return element.innerHTML;
  }
  function report(message) {
    window.webkit?.messageHandlers?.markdownImage?.postMessage(message);
  }
  function readableFailure(element, kind, source) {
    element.replaceChildren();
    const label = document.createElement('p'); label.textContent = kind + ' preview unavailable. Original notation:';
    const code = document.createElement('pre'); code.textContent = source;
    element.append(label, code); element.className = 'rf-error';
  }
  async function render(source) {
    const revision = ++generation;
    observer?.disconnect(); images = [];
    if (new TextEncoder().encode(source).length > 2097152) throw new Error('Markdown exceeds the 2 MiB preview limit.');
    const blocks = [], nonce = 'rf-' + crypto.getRandomValues(new Uint32Array(4)).join('-') + '-';
    function placeholder(kind, text, display) {
      const index = blocks.length; blocks.push({kind,text,display});
      return '<span id="' + nonce + index + '">' + escape(text) + '</span>';
    }
    const parser = new marked.Marked({gfm: true, breaks: false});
    parser.use({renderer: {
      code({text,lang}) {
        if ((lang || '').trim().toLowerCase() === 'mermaid') return placeholder('diagram',text,true);
        return '<pre><code>' + escape(text) + '</code></pre>';
      }
    }, extensions: [
      {name:'displayMath',level:'block',start(src) {
         // Marked passes the paragraph after its first character. Interrupt it only
         // at a complete display block on a new line, never at an inline delimiter.
         const match = /\n(?=(?:\$\$[\s\S]+?\$\$|\\\[[\s\S]+?\\\])(?:\n|$))/.exec(src);
         return match ? match.index + 1 : undefined;
       },
       tokenizer(src) {
         const match = /^(?:\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\])(?:\n|$)/.exec(src);
         if (match) return {type:'displayMath',raw:match[0],text:match[1] ?? match[2]};
       }, renderer(token) { return placeholder('math',token.text,true); }},
      {name:'inlineMath',level:'inline',start(src) { return src.search(/\$|\\\(/); },
       tokenizer(src) {
         // Dollar math cannot start/end with whitespace or end before a digit; common prices remain literal.
         const match = /^(?:\$\$([^\n]+?)\$\$|\$(?!\s)([^$\n]*?[^\s$])\$(?!\d)|\\\(([^\n]+?)\\\))/.exec(src);
         if (match) return {type:'inlineMath',raw:match[0],text:match[1] ?? match[2] ?? match[3],display:match[1] !== undefined};
       }, renderer(token) { return placeholder('math',token.text,token.display); }}
    ]});
    // Sanitize the complete parser output, including raw HTML;
    // only app-generated, unguessable IDs are retained to replace notation placeholders.
    const fragment = DOMPurify.sanitize(parser.parse(source), {ALLOWED_TAGS:tags, ALLOWED_ATTR:[...attributes,'id'],
      ALLOW_DATA_ATTR:false, ALLOW_ARIA_ATTR:false, RETURN_DOM_FRAGMENT:true});
    for (const node of fragment.querySelectorAll('[id]')) if (!node.id.startsWith(nonce)) node.removeAttribute('id');
    for (const link of fragment.querySelectorAll('a')) {
      const href = link.getAttribute('href') || '';
      if (/^(?:javascript|data|file|vbscript):/i.test(href) || href.startsWith('//')) link.removeAttribute('href');
    }
    for (const img of fragment.querySelectorAll('img')) {
      const reference = img.getAttribute('src') || '', alt = img.getAttribute('alt') || reference;
      const button = document.createElement('button'); button.type = 'button'; button.className = 'rf-image';
      button.textContent = alt || 'Image';
      if (images.length < 128 && reference && !/^(?:[a-z][a-z\d+.-]*:|\/\/)/i.test(reference)) {
        const index = images.length; images.push({reference,alt,button,requested:false});
        button.dataset.imageIndex = String(index);
        button.addEventListener('click', () => report({kind:'open',index,generation:revision}));
      } else { button.disabled = true; button.textContent += ' (external image blocked)'; }
      img.replaceWith(button);
    }
    const root = document.getElementById('rf-content'); root.replaceChildren(fragment);
    for (const link of root.querySelectorAll('a[href]')) link.addEventListener('click', event => {
      event.preventDefault(); const reference = link.getAttribute('href');
      if (reference.startsWith('#')) {
        try { document.getElementById(decodeURIComponent(reference.slice(1)))?.scrollIntoView({block:'start'}); } catch {}
      } else report({kind:'link',reference,generation:revision});
    });
    // Headings get stable IDs using the same algorithm as DocumentTextIndex; duplicate IDs are unique.
    const used = new Set(), suffixes = new Map();
    for (const heading of root.querySelectorAll('h1,h2,h3,h4,h5,h6')) {
      const base = heading.textContent.trim().toLowerCase().replace(/[^\p{L}\p{N}\s_-]/gu,'').replace(/\s/g,'-');
      let suffix = suffixes.get(base) || 0, id = suffix ? base + '-' + suffix : base;
      while (used.has(id)) { suffix++; id = base + '-' + suffix; }
      used.add(id); suffixes.set(base,suffix+1); heading.id = id;
    }
    mermaid.initialize({startOnLoad:false, securityLevel:'strict', suppressErrorRendering:true,
      maxTextSize:32768, maxEdges:250, htmlLabels:false, flowchart:{htmlLabels:false},
      theme:matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default'});
    let diagramCount = 0, mathCount = 0;
    for (let index = 0; index < blocks.length; index++) {
      if (generation !== revision) return;
      const block = blocks[index], element = document.getElementById(nonce + index);
      if (!element) continue;
      if (block.kind === 'math') {
        if (++mathCount > 128 || block.text.length > 16384) { readableFailure(element,'Math',block.text); continue; }
        try {
          element.className = block.display ? 'rf-math-display' : 'rf-math';
          element.innerHTML = katex.renderToString(block.text, {displayMode:!!block.display,
            output:'mathml', throwOnError:true, trust:false, strict:'error', maxExpand:500, maxSize:20});
        } catch { readableFailure(element,'Math',block.text); }
      } else {
        // Configuration directives/frontmatter may otherwise override security or inject theme CSS.
        if (++diagramCount > 32 || block.text.length > 32768 || /%%\s*\{|^\s*---/m.test(block.text)) {
          readableFailure(element,'Diagram',block.text); continue;
        }
        try {
          const result = await mermaid.render(nonce + 'diagram-' + index, block.text);
          if (generation !== revision) return;
          const safe = DOMPurify.sanitize(result.svg, {USE_PROFILES:{svg:true,svgFilters:true},
            FORBID_TAGS:['foreignObject','image','a'], FORBID_ATTR:['href','xlink:href'], RETURN_DOM_FRAGMENT:true});
          element.className = 'rf-diagram'; element.setAttribute('role','img');
          element.setAttribute('aria-label','Mermaid diagram: ' + block.text.slice(0,1000)); element.replaceChildren(safe);
        } catch { readableFailure(element,'Diagram',block.text); }
      }
    }
    observer = new IntersectionObserver(entries => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue;
        const index = Number(entry.target.dataset.imageIndex), image = images[index];
        if (!image || image.requested) continue;
        image.requested = true; report({kind:'load',index,generation:revision});
      }
    }, {rootMargin:'300px'});
    for (const image of images) observer.observe(image.button);
    document.documentElement.dataset.rendered = 'true';
    return {generation:revision,images:images.map(image => ({reference:image.reference,alt:image.alt}))};
  }
  function setImage(index, revision, data, error) {
    if (revision !== generation || !images[index]) return;
    const image = images[index];
    if (error) { image.button.textContent = image.alt + ' — ' + error; return; }
    image.loaded = true;
    const node = document.createElement('img'); node.src = data; node.alt = image.alt;
    image.button.replaceChildren(node); image.button.setAttribute('aria-label','Open image ' + image.alt);
  }
  function reveal(text, occurrence, heading) {
    if (heading !== null) {
      const element = heading ? document.getElementById(heading) : document.getElementById('rf-content');
      if (element) { element.scrollIntoView({block:'start'}); return true; }
    }
    const root = document.getElementById('rf-content'), nodes = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node, all = '';
    while ((node = walker.nextNode())) {
      if (node.parentElement.closest('math,svg')) continue;
      nodes.push({node,start:all.length}); all += node.textContent;
    }
    const fold = text => text.normalize('NFD').replace(/\p{M}/gu,'').toLowerCase();
    const target = fold(text); if (!target) return false;
    // Search each original UTF-16 character's folded equivalent while retaining a mapping to DOM offsets.
    let folded = '', offsets = [];
    for (let index = 0; index < all.length; ) {
      const char = String.fromCodePoint(all.codePointAt(index)), piece = fold(char);
      for (let j = 0; j < piece.length; j++) offsets.push(index);
      folded += piece; index += char.length;
    }
    let start = -1;
    for (let i = 0; i <= occurrence; i++) { start = folded.indexOf(target,start < 0 ? 0 : start + target.length); if (start < 0) return false; }
    const originalStart = offsets[start], originalEnd = (offsets[start+target.length] ?? all.length);
    const first = nodes.findLast(item => item.start <= originalStart), last = nodes.findLast(item => item.start < originalEnd);
    if (!first || !last) return false;
    const range = document.createRange(); range.setStart(first.node,originalStart-first.start); range.setEnd(last.node,originalEnd-last.start);
    const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
    first.node.parentElement.scrollIntoView({block:'center'}); return true;
  }
  function resumeImages() {
    for (const image of images) if (!image.loaded) {
      image.requested = false; observer?.unobserve(image.button); observer?.observe(image.button);
    }
  }
  window.RemoteFilesMarkdown = {render,setImage,reveal,resumeImages};
})();
