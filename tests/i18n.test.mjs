import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeLocale, directionFor, translate } from '../src/i18n.mjs';

test('normalizes supported language tags and safely falls back to French', () => {
  assert.equal(normalizeLocale('ar-DZ'), 'ar');
  assert.equal(normalizeLocale('EN-us'), 'en');
  assert.equal(normalizeLocale('de'), 'fr');
});

test('uses right-to-left direction only for Arabic', () => {
  assert.equal(directionFor('ar'), 'rtl');
  assert.equal(directionFor('fr'), 'ltr');
});

test('translates interface labels and falls back to French for missing strings', () => {
  assert.equal(translate('ar', 'cart'), 'السلة');
  assert.equal(translate('en', 'cart'), 'Cart');
  assert.equal(translate('ar', 'untranslatedKey'), 'untranslatedKey');
});
