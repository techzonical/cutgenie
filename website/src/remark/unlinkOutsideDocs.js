// Some pages link to files outside docs/ (CHANGELOG.md, the repo README).
// Those work on GitHub but don't exist on the website, so here we keep the
// words and drop the link. The source pages stay unchanged.
const path = require('path');
const docsDir = path.resolve(__dirname, '../../../docs');

module.exports = function unlinkOutsideDocs() {
  return (tree, file) => {
    const here = path.dirname(file.path);
    const walk = (node) => {
      if (!node.children) return;
      node.children = node.children.flatMap((child) => {
        if (child.type === 'link' && !/^[a-z]+:|^#/i.test(child.url)) {
          const target = path.resolve(here, child.url.split('#')[0]);
          if (!target.startsWith(docsDir)) return child.children;
        }
        walk(child);
        return [child];
      });
    };
    walk(tree);
  };
};
