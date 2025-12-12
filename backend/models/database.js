// Banco de dados em memória (substituir por MongoDB/PostgreSQL em produção)
const orders = new Map();
const collaterals = new Map();
const escrows = new Map();

module.exports = {
  orders,
  collaterals,
  escrows
};
