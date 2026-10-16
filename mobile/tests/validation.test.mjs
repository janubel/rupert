import test from 'node:test';
import assert from 'node:assert/strict';
import { instanceOrigin, localDay, weekBounds } from '../src/validation.mjs';
test('credentials only go to a clean HTTPS instance origin', () => {
  assert.equal(instanceOrigin(' https://rupert.example/ '), 'https://rupert.example');
  for (const bad of ['http://example.com', 'https://user:pass@example.com', 'https://example.com/path', 'https://example.com/?token=secret', 'https://example.com/#secret']) assert.throws(() => instanceOrigin(bad));
});
test('week periods use device local calendar days through Sunday', () => {
  assert.deepEqual(weekBounds(new Date(2026, 9, 18, 23, 59)), { period_start: '2026-10-12', period_end: '2026-10-18' });
  assert.equal(localDay(new Date(2026, 0, 1, 0, 1)), '2026-01-01');
});
