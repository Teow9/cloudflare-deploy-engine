import React from 'react';
import { createRoot } from 'react-dom/client';

// 占位符在字符串字面量中安全（构建产物保留，部署展开时替换）
const SITE_TITLE = '{{site_title}}';
const SITE_TAGLINE = '{{site_tagline}}';

function App() {
  return (
    <main className="hero">
      <h1>{SITE_TITLE}</h1>
      <p className="tagline">{SITE_TAGLINE}</p>
    </main>
  );
}

createRoot(document.getElementById('root')).render(<App />);