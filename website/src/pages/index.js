import React from 'react';
import Layout from '@theme/Layout';
import Link from '@docusaurus/Link';
import useBaseUrl from '@docusaurus/useBaseUrl';
import chapters from '../data-chapters';

const clips = [
  { w: 22, c: '#4a7bd1' }, { w: 14, c: '#4a7bd1' }, { w: 9, cut: true },
  { w: 25, c: '#4a7bd1' }, { w: 25, c: '#9a6bd8' },
];

export default function Home() {
  return (
    <Layout title="Docs" description="Friendly guides for Cutgenie, the free Mac video editor you can drive by hand or with Claude.">
      <header className="cg-hero">
        <div className="cg-hero__inner">
          <div className="cg-hero__copy">
            <p className="cg-eyebrow">Cutgenie docs</p>
            <h1 className="cg-hero__title">Your wish is<br />my <em>edit.</em></h1>
            <p className="cg-hero__lead">Learn Cutgenie step by step, or tell Claude what you want.</p>
            <div className="cg-hero__buttons">
              <Link className="cg-btn cg-btn--primary" to="/getting-started/what-is-cutgenie">Start editing →</Link>
              <Link className="cg-btn cg-btn--ghost" to="/editing-with-claude/how-it-works">✦ Edit with Claude</Link>
            </div>
          </div>
          <div className="cg-hero__art">
            <div className="cg-bubble">“Trim the boring bit?<br />Poof! Done.” <span>✦</span></div>
            <img src={useBaseUrl('/img/genie.svg')} alt="A friendly genie rising from a lamp, holding a magic blade" />
          </div>
        </div>
        <div className="cg-timeline" aria-hidden="true">
          <div className="cg-timeline__pill">✦ removing 3 long pauses…</div>
          <div className="cg-track"><span>V1</span><div className="cg-track__clips">
            {clips.map((k, i) => <i key={i} className={k.cut ? 'cut' : ''} style={{ flex: k.w, background: k.c }} />)}
          </div></div>
          <div className="cg-track"><span>A1</span><div className="cg-track__clips"><i className="wave" style={{ flex: 1 }} /></div></div>
          <b className="cg-playhead" />
        </div>
      </header>
      <main className="cg-chapters">
        <h2>Pick a chapter</h2>
        <div className="cg-cards">
          {chapters.map((c) => (
            <Link key={c.n} to={c.to} className={'cg-card' + (c.star ? ' cg-card--star' : '')} style={{ '--c': c.color }}>
              <small>{c.n}{c.star ? ' · ✦' : ''}</small>
              <h3>{c.title}</h3>
              <p>{c.text}</p>
            </Link>
          ))}
        </div>
      </main>
    </Layout>
  );
}
