/* Shared Mathcolate math input and rendering support.
 * Store source text (including LaTeX delimiters), never rendered HTML.
 */
(function () {
  'use strict';
  const CSS = 'https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.css';
  const KATEX = 'https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/katex.min.js';
  const AUTO = 'https://cdn.jsdelivr.net/npm/katex@0.16.22/dist/contrib/auto-render.min.js';
  let loading;
  const editorSelector = '#stem-en, #stem-zh, #explain-en, #explain-zh, #instructions-en, [data-choice-en], [data-choice-zh]';

  function loadMath() {
    if (window.renderMathInElement && window.katex) return Promise.resolve();
    if (loading) return loading;
    loading = new Promise((resolve, reject) => {
      if (!document.querySelector('link[data-mathcolate-katex]')) {
        const link = document.createElement('link');
        link.rel = 'stylesheet'; link.href = CSS; link.dataset.mathcolateKatex = '1';
        document.head.appendChild(link);
      }
      function script(src, done) {
        const existing = document.querySelector('script[data-mathcolate-src="' + src + '"]');
        if (existing) {
          if (existing.dataset.loaded === '1') return done();
          existing.addEventListener('load', done, { once: true });
          existing.addEventListener('error', () => reject(new Error('Unable to load math renderer.')), { once: true });
          return;
        }
        const s = document.createElement('script');
        s.src = src; s.dataset.mathcolateSrc = src;
        s.onload = () => { s.dataset.loaded = '1'; done(); };
        s.onerror = () => reject(new Error('Unable to load math renderer.'));
        document.head.appendChild(s);
      }
      script(KATEX, () => script(AUTO, resolve));
    });
    return loading;
  }

  function render(root) {
    if (!window.renderMathInElement || !root) return;
    const targets = [];
    if (root.nodeType === 1 && root.matches && root.matches('[data-math-render], .math-content')) targets.push(root);
    if (root.querySelectorAll) targets.push(...root.querySelectorAll('[data-math-render], .math-content'));
    if (!targets.length && root === document) targets.push(document.body);
    targets.forEach(el => {
      if (el.dataset.mathRendered === '1') delete el.dataset.mathRendered;
      try {
        window.renderMathInElement(el, {
          delimiters: [
            { left: '$$', right: '$$', display: true },
            { left: '\\[', right: '\\]', display: true },
            { left: '\\(', right: '\\)', display: false },
            { left: '$', right: '$', display: false }
          ],
          throwOnError: false,
          strict: 'ignore',
          ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code', 'option', 'input']
        });
        el.dataset.mathRendered = '1';
      } catch (e) { console.warn('Mathcolate formula render skipped', e); }
    });
  }

  function insertAtCursor(input, before, after) {
    const start = input.selectionStart == null ? input.value.length : input.selectionStart;
    const end = input.selectionEnd == null ? start : input.selectionEnd;
    const selected = input.value.slice(start, end) || 'x';
    const insertion = before + selected + after;
    input.setRangeText(insertion, start, end, 'select');
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.focus();
  }

  function preview(input, host) {
    if (!host) return;
    host.textContent = input.value || ' ';
    loadMath().then(() => {
      if (!host.isConnected) return;
      host.innerHTML = '';
      host.textContent = input.value || ' ';
      try {
        window.renderMathInElement(host, {
          delimiters: [
            { left: '$$', right: '$$', display: true },
            { left: '\\[', right: '\\]', display: true },
            { left: '\\(', right: '\\)', display: false },
            { left: '$', right: '$', display: false }
          ], throwOnError: false, strict: 'ignore',
          ignoredTags: ['script', 'noscript', 'style', 'textarea', 'pre', 'code', 'option', 'input']
        });
      } catch (_) {}
    }).catch(() => {});
  }

  function insertTemplate(input, template) {
    const start = input.selectionStart == null ? input.value.length : input.selectionStart;
    const end = input.selectionEnd == null ? start : input.selectionEnd;
    const wrapped = '\\\\(' + template + '\\\\)';
    input.setRangeText(wrapped, start, end, 'end');
    const brace = input.value.indexOf('{}', start);
    if (brace >= 0 && brace < start + wrapped.length) input.setSelectionRange(brace + 1, brace + 1);
    input.dispatchEvent(new Event('input', { bubbles: true }));
    input.focus();
  }

  function enhance(input) {
    if (!input || input.dataset.mathEditorReady === '1' || input.disabled || input.readOnly) return;
    if (input.type === 'hidden' || input.type === 'file' || input.type === 'checkbox' || input.type === 'radio') return;
    input.dataset.mathEditorReady = '1';
    const wrap = document.createElement('div');
    wrap.className = 'math-editor-wrap';
    input.parentNode.insertBefore(wrap, input);
    wrap.appendChild(input);
    const toolbar = document.createElement('div');
    toolbar.className = 'math-editor-toolbar';
    toolbar.innerHTML =
      '<span class="math-editor-label">Math</span>' +
      '<button type="button" data-math-insert="inline" title="Insert inline formula">ƒ(x)</button>' +
      '<button type="button" data-math-insert="display" title="Insert display formula">∑</button>' +
      '<button type="button" data-math-template="\\frac{}{}" title="Insert fraction">a⁄b</button>' +
      '<button type="button" data-math-template="x^{}" title="Insert power">xⁿ</button>' +
      '<button type="button" data-math-template="\\sqrt{}" title="Insert square root">√x</button>';
    const output = document.createElement('div');
    output.className = 'math-editor-preview';
    output.setAttribute('aria-live', 'polite');
    output.innerHTML = '<span class="math-editor-preview-label">Preview</span><div class="math-editor-preview-content"></div>';
    wrap.appendChild(toolbar);
    wrap.appendChild(output);
    const previewHost = output.querySelector('.math-editor-preview-content');
    toolbar.addEventListener('click', event => {
      const button = event.target.closest('button');
      if (!button) return;
      if (button.dataset.mathInsert === 'inline') insertAtCursor(input, '\\(', '\\)');
      else if (button.dataset.mathInsert === 'display') insertAtCursor(input, '\\[', '\\]');
      else if (button.dataset.mathTemplate) {
        insertTemplate(input, button.dataset.mathTemplate);
      }
    });
    input.addEventListener('input', () => preview(input, previewHost));
    preview(input, previewHost);
  }

  function scan(root) {
    if (!root) return;
    if (root.matches && root.matches(editorSelector)) enhance(root);
    if (root.querySelectorAll) root.querySelectorAll(editorSelector).forEach(enhance);
    render(root);
  }

  const style = document.createElement('style');
  style.textContent = `
    .math-editor-wrap { margin-top: .45rem; }
    .math-editor-wrap > textarea, .math-editor-wrap > input { margin-top: 0 !important; }
    .math-editor-toolbar { display:flex; align-items:center; flex-wrap:wrap; gap:.35rem; margin-top:.4rem; }
    .math-editor-label, .math-editor-preview-label { font-size:.7rem; font-weight:700; color:#6b7280; margin-right:.2rem; }
    .math-editor-toolbar button { border:1px solid #e5e7eb; border-radius:.45rem; background:#fff; color:#5c3a18; padding:.2rem .55rem; font-size:.75rem; font-weight:600; }
    .math-editor-toolbar button:hover { background:#fdf8f6; border-color:#c9a27e; }
    .math-editor-preview { border:1px dashed #e5e7eb; border-radius:.55rem; background:#fafafa; padding:.5rem .65rem; margin-top:.4rem; min-height:2rem; overflow-x:auto; font-size:.9rem; font-weight:400; white-space:pre-wrap; }
    .math-editor-preview-label { display:block; margin-bottom:.25rem; }
    .math-editor-preview-content { white-space:normal; overflow-wrap:anywhere; min-height:.8rem; }
    .math-editor-preview-content .katex-display { margin:.35rem 0; text-align:left; }
    [data-math-render] .katex-display, .math-content .katex-display { overflow-x:auto; overflow-y:hidden; padding:.15rem 0; }
  `;
  document.head.appendChild(style);

  loadMath().then(() => scan(document)).catch(error => console.warn('Mathcolate math renderer unavailable', error));
  scan(document);
  const observer = new MutationObserver(records => {
    for (const record of records) for (const node of record.addedNodes) {
      if (node.nodeType === 1) scan(node);
    }
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  window.MathcolateMath = {
    render: function (root) { loadMath().then(() => render(root || document.body)).catch(() => {}); },
    insertInline: function (input) { insertAtCursor(input, '\\(', '\\)'); },
    insertDisplay: function (input) { insertAtCursor(input, '\\[', '\\]'); }
  };
})();
