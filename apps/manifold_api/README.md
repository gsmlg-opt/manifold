# ManifoldAPI

Phoenix API-only HTTP interface for Manifold mail read and search.

Exposes versioned REST under `/api/v1` and GraphQL under `/api/graphql` on a
separate port (`API_PORT`, default `4292`). Clients can discover entry points via
`GET /.well-known/manifold`. Access is trusted at the deployment network boundary
rather than through application login.
