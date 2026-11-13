(() => {
  const content = document.getElementById('content');
  const allowedTags = ['#text', 'a', 'p', 'br', 'strong', 'em', 'del', 'code', 'pre', 'blockquote', 'ul', 'ol', 'li', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'hr', 'table', 'thead', 'tbody', 'tr', 'th', 'td', 'input', 'img', 'sup', 'section', 'div', 'span'];
  const allowedAttributes = ['href', 'src', 'alt', 'title', 'class', 'id', 'type', 'checked', 'disabled', 'start', 'align', 'colspan', 'rowspan', 'aria-label', 'aria-describedby'];
  const scripts = new Map();
  let blocks = [];
  let dragging = false;
  let pending = null;
  let diagramID = 0;
  let lastHeight = 0;

  function send(message) {
    window.webkit?.messageHandlers?.markdown?.postMessage(message);
  }

  function reportSize() {
    const height = Math.ceil(content.getBoundingClientRect().height);
    if (height !== lastHeight) {
      lastHeight = height;
      send({ type: 'size', height });
    }
  }

  function safeURL(value, image) {
    if (!value) return false;
    if (!image && value.startsWith('#')) return true;
    if (image && /^data:image\/(png|jpeg|gif|webp);base64,/i.test(value)) return true;
    try {
      const url = new URL(value, location.href);
      return url.protocol === 'https:' || url.protocol === 'http:' || (!image && url.protocol === 'mailto:');
    } catch (_) {
      return false;
    }
  }

  function sanitize(html) {
    let fragment;
    if (typeof Document.parseHTML === 'function') {
      try {
        const doc = Document.parseHTML(html, { sanitizer: { elements: allowedTags.filter(tag => tag !== '#text'), attributes: allowedAttributes } });
        fragment = document.createDocumentFragment();
        fragment.append(...doc.body.childNodes);
      } catch (_) {}
    }
    if (!fragment) {
      fragment = DOMPurify.sanitize(html, {
        RETURN_DOM_FRAGMENT: true,
        ALLOWED_TAGS: allowedTags,
        ALLOWED_ATTR: allowedAttributes,
        ALLOW_DATA_ATTR: false,
        KEEP_CONTENT: false
      });
    }
    fragment.querySelectorAll('a[href], img[src]').forEach(element => {
      const image = element.tagName === 'IMG';
      const attribute = image ? 'src' : 'href';
      if (!safeURL(element.getAttribute(attribute), image)) element.removeAttribute(attribute);
      if (image) element.setAttribute('loading', 'lazy');
    });
    fragment.querySelectorAll('input').forEach(input => {
      if (input.getAttribute('type') !== 'checkbox') input.remove();
      else input.disabled = true;
    });
    return fragment;
  }

  function selectionSnapshot() {
    const selection = window.getSelection();
    if (!selection || selection.isCollapsed || !content.contains(selection.anchorNode) || !content.contains(selection.focusNode)) return null;
    const offset = (node, position) => {
      const range = document.createRange();
      range.selectNodeContents(content);
      range.setEnd(node, position);
      return range.toString().length;
    };
    return { anchor: offset(selection.anchorNode, selection.anchorOffset), focus: offset(selection.focusNode, selection.focusOffset) };
  }

  function restoreSelection(snapshot) {
    if (!snapshot) return;
    const pointAt = offset => {
      const walker = document.createTreeWalker(content, NodeFilter.SHOW_TEXT);
      let node;
      let last = content;
      while ((node = walker.nextNode())) {
        last = node;
        if (offset <= node.length) return [node, offset];
        offset -= node.length;
      }
      return [last, last.nodeType === Node.TEXT_NODE ? last.length : last.childNodes.length];
    };
    const [anchor, anchorOffset] = pointAt(snapshot.anchor);
    const [focus, focusOffset] = pointAt(snapshot.focus);
    const selection = window.getSelection();
    selection.setBaseAndExtent(anchor, anchorOffset, focus, focusOffset);
  }

  function preserveSelection(action) {
    const snapshot = selectionSnapshot();
    action();
    restoreSelection(snapshot);
  }

  function loadScript(path) {
    if (!scripts.has(path)) {
      scripts.set(path, new Promise((resolve, reject) => {
        const script = document.createElement('script');
        script.src = path;
        script.onload = resolve;
        script.onerror = reject;
        document.head.appendChild(script);
      }));
    }
    return scripts.get(path);
  }

  function loadMath() {
    if (!document.getElementById('katex-style')) {
      const link = document.createElement('link');
      link.id = 'katex-style';
      link.rel = 'stylesheet';
      link.href = 'css/katex.min.css';
      document.head.appendChild(link);
    }
    return loadScript('js/katex.min.js').then(() => loadScript('js/auto-render.min.js'));
  }

  function protectCurrency(root) {
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT, {
      acceptNode(node) {
        return node.data.includes('$') && !node.parentElement?.closest('pre, code, .katex, .skip-math-dollar')
          ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
      }
    });
    const nodes = [];
    while (walker.nextNode()) nodes.push(walker.currentNode);
    const currency = /\$(?![0-9]+(?:[.,][0-9]+)?[$(])([0-9]+(?:[.,][0-9]+)?)(?=$|[^0-9A-Za-z+\-*/=<>^_\\])/g;
    for (const node of nodes) {
      const text = node.data;
      const fragment = document.createDocumentFragment();
      let previous = 0;
      let match;
      currency.lastIndex = 0;
      while ((match = currency.exec(text))) {
        fragment.append(document.createTextNode(text.slice(previous, match.index)));
        const span = document.createElement('span');
        span.className = 'skip-math-dollar';
        span.textContent = match[0];
        fragment.append(span);
        previous = match.index + match[0].length;
      }
      if (previous) {
        fragment.append(document.createTextNode(text.slice(previous)));
        node.replaceWith(fragment);
      }
    }
  }

  async function renderDiagram(pre, source) {
    const version = pre.__diagramVersion = (pre.__diagramVersion || 0) + 1;
    try {
      await loadScript('js/mermaid.min.js');
      if (!pre.isConnected || pre.__diagramSource !== source || pre.__diagramVersion !== version) return;
      mermaid.initialize({
        startOnLoad: false,
        securityLevel: 'strict',
        suppressErrorRendering: true,
        secure: ['secure', 'securityLevel', 'startOnLoad', 'maxTextSize', 'maxEdges', 'suppressErrorRendering', 'htmlLabels', 'themeCSS'],
        theme: document.documentElement.dataset.theme === 'dark' ? 'dark' : 'default',
        htmlLabels: false
      });
      const { svg } = await mermaid.render(`maus-diagram-${++diagramID}`, source);
      if (!pre.isConnected || pre.__diagramSource !== source || pre.__diagramVersion !== version) return;
      const clean = DOMPurify.sanitize(svg, {
        RETURN_DOM_FRAGMENT: true,
        USE_PROFILES: { svg: true, svgFilters: true },
        FORBID_TAGS: ['script', 'foreignObject', 'iframe'],
        FORBID_ATTR: ['href', 'xlink:href']
      });
      preserveSelection(() => pre.replaceChildren(clean));
      pre.classList.add('diagram');
      reportSize();
    } catch (_) {
      reportSize();
    }
  }

  function enhance(nodes, containsMath) {
    const elements = nodes.filter(node => node.nodeType === Node.ELEMENT_NODE);
    const codeBlocks = elements.flatMap(element => [element, ...element.querySelectorAll('pre code')])
      .filter(element => element.matches('pre code'));
    const highlights = codeBlocks.filter(code => !code.classList.contains('language-mermaid'));
    if (highlights.length) {
      loadScript('js/highlight.min.js').then(() => {
        preserveSelection(() => highlights.filter(code => code.isConnected).forEach(code => {
          const language = [...code.classList].find(name => name.startsWith('language-'))?.slice(9);
          if (language && hljs.getLanguage(language)) hljs.highlightElement(code);
        }));
        reportSize();
      }).catch(() => {});
    }
    codeBlocks.filter(code => code.classList.contains('language-mermaid')).forEach(code => {
      const pre = code.closest('pre');
      pre.__diagramSource = code.textContent;
      setTimeout(() => { if (pre.isConnected) renderDiagram(pre, pre.__diagramSource); }, 300);
    });
    if (containsMath && elements.length) {
      loadMath().then(() => {
        preserveSelection(() => elements.filter(element => element.isConnected).forEach(element => {
          protectCurrency(element);
          renderMathInElement(element, {
            delimiters: [
              { left: '$$', right: '$$', display: true },
              { left: '$', right: '$', display: false },
              { left: '\\(', right: '\\)', display: false },
              { left: '\\[', right: '\\]', display: true }
            ],
            ignoredClasses: ['katex', 'skip-math-dollar'],
            throwOnError: false,
            trust: false
          });
        }));
        reportSize();
      }).catch(() => {});
    }
  }

  function render(data) {
    if (dragging) { pending = data; return; }
    const fresh = [...sanitize(data.html).childNodes]
      .filter(node => node.nodeType !== Node.TEXT_NODE || node.textContent.trim())
      .map(node => ({ node, key: node.nodeType === Node.ELEMENT_NODE ? node.outerHTML : node.textContent }));
    let start = 0;
    while (start < blocks.length && start < fresh.length && blocks[start].key === fresh[start].key) start++;
    let oldEnd = blocks.length;
    let newEnd = fresh.length;
    while (oldEnd > start && newEnd > start && blocks[oldEnd - 1].key === fresh[newEnd - 1].key) { oldEnd--; newEnd--; }
    const inserted = fresh.slice(start, newEnd);
    preserveSelection(() => {
      const reference = oldEnd < blocks.length ? blocks[oldEnd].node : null;
      blocks.slice(start, oldEnd).forEach(block => block.node.remove());
      inserted.forEach(block => content.insertBefore(block.node, reference));
      blocks = [...blocks.slice(0, start), ...inserted, ...blocks.slice(oldEnd)];
    });
    enhance(inserted.map(block => block.node), data.containsMath);
    reportSize();
  }

  function setAppearance(theme, fontFamily) {
    const changed = document.documentElement.dataset.theme !== theme;
    document.documentElement.dataset.theme = theme;
    content.style.fontFamily = fontFamily ? `"${fontFamily.replace(/["\\]/g, '\\$&')}", -apple-system, sans-serif` : '';
    if (changed) {
      content.querySelectorAll('pre.diagram').forEach(pre => {
        if (pre.__diagramSource) renderDiagram(pre, pre.__diagramSource);
      });
    }
    reportSize();
  }

  content.addEventListener('mousedown', () => { dragging = true; });
  window.addEventListener('mouseup', () => {
    dragging = false;
    if (pending) { const latest = pending; pending = null; render(latest); }
  });
  window.addEventListener('blur', () => {
    dragging = false;
    if (pending) { const latest = pending; pending = null; render(latest); }
  });
  window.addEventListener('resize', reportSize);
  new ResizeObserver(reportSize).observe(content);
  document.fonts?.ready.then(reportSize);
  window.markdownPreview = { render, setAppearance };
  send({ type: 'ready' });
})();
