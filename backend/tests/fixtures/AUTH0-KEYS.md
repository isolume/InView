`auth0-test-key.pem` and `auth0-other-key.pem` are throwaway RSA keys generated only to sign
tokens in `tests/auth0.rs`; `auth0-test-jwks.json` is the public half of the first. They protect
nothing and are not related to any Auth0 tenant.
