// Configuração do portal — ajuste por ambiente (dev/staging/prod).
// A anon key é publicável por design (RLS protege os dados); segredos de
// gateway/e-mail NUNCA entram aqui (§103).
window.PORTAL_CONFIG = {
  SUPABASE_URL: "https://rxcfbbzosbfiwyloqtdk.supabase.co",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJ4Y2ZiYnpvc2JmaXd5bG9xdGRrIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc5MzE4MTEsImV4cCI6MjEwMzUwNzgxMX0.g1hXBzu2dYjyggOPWKVadxgHQRlwQ7ebQqRk4i-Z3F4",
  // Terminal principal publicado no mesmo domínio.
  LINK_TERMINAL: "/terminal/",
  AMBIENTE: "production" // development | staging | production
};
