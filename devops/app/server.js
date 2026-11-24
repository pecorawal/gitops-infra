// Servidor HTTP mínimo (módulo nativo "http"). Rotas:
//   /               página com versão, cor e ambiente (o que se mostra na demo)
//   /api/pagamentos simula uma transação aprovada
//   /health         probe de liveness/readiness
const http = require('http');
const { pagamento, saude, pagina } = require('./lib');

const PORT = process.env.PORT || 8080;

function rotear(req, res) {
  const json = (codigo, corpo) => {
    res.writeHead(codigo, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(corpo));
  };
  if (req.url === '/health') return json(200, saude());
  if (req.url === '/api/pagamentos') return json(200, pagamento());
  if (req.url === '/') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(pagina());
  }
  return json(404, { error: 'no encontrado' });
}

if (require.main === module) {
  http.createServer(rotear).listen(PORT, () => {
    console.log(`pagamentos-api escutando na porta ${PORT}`);
  });
}

module.exports = { rotear };
