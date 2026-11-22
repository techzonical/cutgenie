// Cutgenie docs website. Pages come straight from ../docs (one source).
const sidebarItemsGenerator = require('./sidebarItemsGenerator');

/** @type {import('@docusaurus/types').Config} */
module.exports = {
  title: 'Cutgenie Docs',
  tagline: 'Your wish is my edit.',
  favicon: 'img/icon.png',
  url: 'https://techzonical.com',
  baseUrl: '/apps/cutgenie/docs/',
  trailingSlash: false,
  onBrokenLinks: 'throw',
  markdown: { hooks: { onBrokenMarkdownLinks: 'warn' } },
  i18n: { defaultLocale: 'en', locales: ['en'] },
  clientModules: [require.resolve('./src/retinaImages.js')],
  stylesheets: [
    'https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,600;0,9..144,800;1,9..144,800&family=DM+Sans:opsz,wght@9..40,400;9..40,500;9..40,700&family=JetBrains+Mono:wght@500&display=swap',
  ],
  themes: [
    [
      require.resolve('@easyops-cn/docusaurus-search-local'),
      {
        hashed: true,
        indexBlog: false,
        docsDir: '../docs',
        docsRouteBasePath: '/',
        highlightSearchTermsOnTargetPage: true,
        searchBarShortcutHint: true,
      },
    ],
  ],
  presets: [
    [
      'classic',
      {
        docs: {
          path: '../docs',
          routeBasePath: '/',
          exclude: ['README.md'],
          sidebarPath: require.resolve('./sidebars.js'),
          sidebarItemsGenerator,
          beforeDefaultRemarkPlugins: [require('./src/remark/unlinkOutsideDocs')],
        },
        blog: false,
        theme: { customCss: require.resolve('./src/css/custom.css') },
      },
    ],
  ],
  themeConfig: {
    colorMode: { defaultMode: 'dark', disableSwitch: true, respectPrefersColorScheme: false },
    image: 'img/genie.svg',
    docs: { sidebar: { hideable: true, autoCollapseCategories: true } },
    tableOfContents: { minHeadingLevel: 2, maxHeadingLevel: 3 },
    footer: {
      style: 'dark',
      copyright: 'Cutgenie · a free Mac video editor by TechZonical',
    },
    navbar: {
      title: 'Cutgenie',
      logo: { alt: 'Cutgenie', src: 'img/icon.png' },
      items: [
        { type: 'docSidebar', sidebarId: 'guide', label: 'Docs', position: 'left' },
        { to: '/editing-with-claude/how-it-works', label: '✦ Edit with Claude', position: 'left' },
        { to: '/shortcuts/keyboard-map', label: 'Shortcuts', position: 'left' },
        { type: 'search', position: 'right' },
      ],
    },
  },
};
