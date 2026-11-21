// Builds the sidebar from each page's frontmatter: `section` names the chapter,
// `order` sorts pages inside it. Chapters follow their folder number (01-, 02-…).
module.exports = async function ({ docs }) {
  const chapters = new Map();
  for (const doc of docs) {
    const section = doc.frontMatter.section || 'Other';
    const folder = doc.sourceDirName.split('/')[0];
    if (!chapters.has(section)) chapters.set(section, { folder, items: [] });
    chapters.get(section).items.push(doc);
  }
  return [...chapters.entries()]
    .sort((a, b) => a[1].folder.localeCompare(b[1].folder))
    .map(([label, { items }]) => ({
      type: 'category',
      label,
      collapsed: true,
      items: items
        .sort((a, b) => (a.frontMatter.order ?? 999) - (b.frontMatter.order ?? 999))
        .map((d) => ({ type: 'doc', id: d.id })),
    }));
};
