export function instanceOrigin(value) {
  const url = new URL(value.trim());
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/' || url.search || url.hash) throw new Error('Enter the HTTPS address of your Rupert instance, without a path.');
  return url.origin;
}
export function localDay(date = new Date()) {
  const pad = value => String(value).padStart(2, '0');
  return `${date.getFullYear()}-${pad(date.getMonth()+1)}-${pad(date.getDate())}`;
}
export function weekBounds(date = new Date()) {
  const start = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  start.setDate(start.getDate() - (start.getDay()+6)%7);
  const end = new Date(start); end.setDate(end.getDate()+6);
  return { period_start: localDay(start), period_end: localDay(end) };
}
