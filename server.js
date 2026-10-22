const http = require("http");

const PORT = Number(process.env.PORT || 8877);

const server = http.createServer(
  {
    maxHeaderSize: 1024,
  },
  (req, res) => {
    if (
      (req.method === "GET" || req.method === "HEAD") &&
      req.url === "/health"
    ) {
      res.writeHead(200, {
        "Content-Type": "text/plain",
        "Cache-Control": "no-store",
        "Content-Length": "2",
      });

      if (req.method === "HEAD") {
        return res.end();
      }

      return res.end("OK");
    }

    res.writeHead(404, {
      "Content-Type": "text/plain",
      "Content-Length": "9",
    });

    return res.end("Not Found");
  }
);

server.requestTimeout = 2000;
server.headersTimeout = 2000;
server.keepAliveTimeout = 1000;

server.on("clientError", (_err, socket) => {
  socket.destroy();
});

server.listen(PORT, "0.0.0.0", () => {
  console.log(`Route53 health endpoint listening on ${PORT}`);
});
