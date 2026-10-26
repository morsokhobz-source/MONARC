import test from 'node:test';
import assert from 'node:assert/strict';
import { calculateTotals, availableStock, canTransition, inventoryEffects } from '../src/domain.mjs';

test('calculates checkout totals from integer prices and quantities', () => {
  assert.deepEqual(
    calculateTotals([{ unitPrice: 3500, quantity: 2 }, { unitPrice: 2000, quantity: 1 }], 500),
    { subtotal: 9000, deliveryFee: 500, total: 9500 }
  );
});

test('rejects invalid quantities, prices, and delivery fees', () => {
  assert.throws(() => calculateTotals([{ unitPrice: 100, quantity: 0 }], 0), /quantity/i);
  assert.throws(() => calculateTotals([{ unitPrice: -1, quantity: 1 }], 0), /price/i);
  assert.throws(() => calculateTotals([{ unitPrice: 0, quantity: 1 }], -1), /delivery/i);
});

test('computes sellable stock after existing reservations', () => {
  assert.equal(availableStock({ onHand: 12, reserved: 5 }), 7);
  assert.throws(() => availableStock({ onHand: 2, reserved: 3 }), /reserved/i);
});

test('permits only valid order status transitions', () => {
  assert.equal(canTransition('pending_confirmation', 'confirmed'), true);
  assert.equal(canTransition('confirmed', 'preparing'), true);
  assert.equal(canTransition('delivered', 'confirmed'), false);
});

test('confirmation reserves stock but does not mark COD as collected', () => {
  assert.deepEqual(inventoryEffects('pending_confirmation', 'confirmed', 2), { onHand: 0, reserved: 2, payment: 'unchanged' });
});

test('cancellation releases a reservation and delivery consumes it', () => {
  assert.deepEqual(inventoryEffects('confirmed', 'cancelled', 2), { onHand: 0, reserved: -2, payment: 'unchanged' });
  assert.deepEqual(inventoryEffects('shipped', 'delivered', 2), { onHand: -2, reserved: -2, payment: 'unchanged' });
});

test('returns do not restock automatically before inspection', () => {
  assert.deepEqual(inventoryEffects('delivered', 'returned', 2), { onHand: 0, reserved: 0, payment: 'unchanged' });
});
