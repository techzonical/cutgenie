// Screenshots are taken on a Retina Mac (2 pixels per point). Show each one at
// its real on-screen size (half its pixel width) so small panel shots don't get
// blown up to the full page width. Big window shots still fill the column.
function fit(img) {
  const apply = () => {
    if (img.naturalWidth) img.style.maxWidth = `min(100%, ${img.naturalWidth / 2}px)`;
  };
  if (img.complete) apply();
  else img.addEventListener('load', apply, { once: true });
}

export function onRouteDidUpdate() {
  if (typeof document === 'undefined') return;
  document.querySelectorAll('.theme-doc-markdown img').forEach(fit);
}
