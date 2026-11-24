// Testes unitários executados pela task npm-test da pipeline (node --test).
// Se algum falhar, a pipeline para ANTES do build: nada chega ao cluster.
const test = require('node:test');
const assert = require('node:assert');
const { pagamento, saude, pagina, VERSAO } = require('../lib');

test('pagamento é aprovado e traz número de transação', () => {
  const p = pagamento();
  assert.strictEqual(p.status, 'Aprobado');
  assert.ok(Number.isInteger(p.transaccion));
});

test('health responde ok com a versão', () => {
  assert.deepStrictEqual(saude(), { status: 'ok', version: VERSAO });
});

test('versão segue o formato MAJOR.MINOR', () => {
  assert.match(VERSAO, /^\d+\.\d+$/);
});

test('página mostra a versão', () => {
  assert.ok(pagina().includes(`v${VERSAO}`));
});
