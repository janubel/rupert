(() => {
  const guides = document.querySelector('.guide-menu');
  document.addEventListener('keydown', event => {
    if (event.key === 'Escape' && guides?.open) {
      guides.open = false;
      guides.querySelector('summary').focus();
    }
  });
  document.addEventListener('click', event => {
    if (guides?.open && !guides.contains(event.target)) guides.open = false;
  });
  const search = document.getElementById('feature-search');
  const status = document.getElementById('feature-status');
  const count = document.getElementById('feature-count');
  const features = [...document.querySelectorAll('[data-feature]')];
  function filterFeatures() {
    let visible = 0;
    const term = search.value.trim().toLowerCase();
    features.forEach(row => {
      row.hidden = !row.dataset.search.includes(term) || (status.value !== 'All' && row.dataset.status !== status.value);
      if (!row.hidden) visible++;
    });
    count.textContent = `${visible} of ${features.length} features`;
  }
  search?.addEventListener('input', filterFeatures);
  status?.addEventListener('change', filterFeatures);
  const matrixSearch = document.getElementById('matrix-search');
  matrixSearch?.addEventListener('input', () => {
    const term = matrixSearch.value.trim().toLowerCase();
    document.querySelectorAll('[data-comparison]').forEach(row => { row.hidden = !row.dataset.search.includes(term); });
  });
})();
