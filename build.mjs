import { cp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises';

await rm('dist', { recursive: true, force: true });
await mkdir('dist/server', { recursive: true });
await mkdir('dist/.openai', { recursive: true });
await cp('index.html', 'dist/index.html');
await cp('styles.css', 'dist/styles.css');
await cp('app.js', 'dist/app.js');
await cp('public', 'dist/public', { recursive: true });
await cp('.openai/hosting.json', 'dist/.openai/hosting.json');
const [html, css, js] = await Promise.all([
  readFile('index.html', 'utf8'),
  readFile('styles.css', 'utf8'),
  readFile('app.js', 'utf8')
]);
const photoFiles = await readdir('public/assets/water');
const photoEntries = await Promise.all(photoFiles.map(async file => [file, (await readFile(`public/assets/water/${file}`)).toString('base64')]));
await writeFile('dist/server/index.js', `
const HTML = ${JSON.stringify(html)};
const CSS = ${JSON.stringify(css)};
const JS = ${JSON.stringify(js)};
const PHOTOS = ${JSON.stringify(Object.fromEntries(photoEntries))};
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname === '/' || url.pathname === '/index.html') return new Response(HTML, { headers: { 'content-type': 'text/html; charset=UTF-8' } });
    if (url.pathname === '/styles.css') return new Response(CSS, { headers: { 'content-type': 'text/css; charset=UTF-8' } });
    if (url.pathname === '/app.js') return new Response(JS, { headers: { 'content-type': 'application/javascript; charset=UTF-8' } });
    if (url.pathname.startsWith('/assets/water/')) {
      const file = decodeURIComponent(url.pathname.split('/').pop());
      const encoded = PHOTOS[file];
      if (encoded) {
        const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
        return new Response(bytes, { headers: { 'content-type': 'image/jpeg', 'cache-control': 'public, max-age=86400' } });
      }
    }
    return new Response('未找到页面', { status: 404 });
  }
};
`);
