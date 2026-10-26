export const ORDER_TRANSITIONS = Object.freeze({
  pending_confirmation: ['confirmed', 'rejected', 'cancelled'],
  confirmed: ['preparing', 'cancelled'],
  preparing: ['shipped', 'cancelled'],
  shipped: ['delivered', 'delivery_failed'],
  delivery_failed: ['returned', 'preparing'],
  delivered: ['returned'],
  returned: [],
  rejected: [],
  cancelled: []
});

function nonNegativeInteger(value, label) {
  if (!Number.isSafeInteger(value) || value < 0) throw new RangeError(`${label} must be a non-negative integer.`);
  return value;
}

export function calculateTotals(items, deliveryFee = 0) {
  if (!Array.isArray(items) || items.length === 0) throw new TypeError('Cart must contain at least one item.');
  nonNegativeInteger(deliveryFee, 'Delivery fee');
  let subtotal = 0;
  for (const item of items) {
    const price = nonNegativeInteger(item.unitPrice, 'Price');
    if (!Number.isSafeInteger(item.quantity) || item.quantity < 1) throw new RangeError('Quantity must be a positive integer.');
    const line = price * item.quantity;
    if (!Number.isSafeInteger(line) || !Number.isSafeInteger(subtotal + line)) throw new RangeError('Order total is too large.');
    subtotal += line;
  }
  const total = subtotal + deliveryFee;
  if (!Number.isSafeInteger(total)) throw new RangeError('Order total is too large.');
  return { subtotal, deliveryFee, total };
}

export function availableStock({ onHand, reserved }) {
  nonNegativeInteger(onHand, 'On-hand stock');
  nonNegativeInteger(reserved, 'Reserved stock');
  if (reserved > onHand) throw new RangeError('Reserved stock cannot exceed on-hand stock.');
  return onHand - reserved;
}

export function canTransition(from, to) {
  return Boolean(ORDER_TRANSITIONS[from]?.includes(to));
}

export function inventoryEffects(from, to, quantity) {
  if (!Number.isSafeInteger(quantity) || quantity < 1) throw new RangeError('Quantity must be a positive integer.');
  if (!canTransition(from, to)) throw new Error(`Invalid order transition: ${from} → ${to}.`);
  if (from === 'pending_confirmation' && to === 'confirmed') return { onHand: 0, reserved: quantity, payment: 'unchanged' };
  if (['confirmed', 'preparing'].includes(from) && to === 'cancelled') return { onHand: 0, reserved: -quantity, payment: 'unchanged' };
  if (from === 'shipped' && to === 'delivered') return { onHand: -quantity, reserved: -quantity, payment: 'unchanged' };
  return { onHand: 0, reserved: 0, payment: 'unchanged' };
}
