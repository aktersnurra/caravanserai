Pocket ID v2.19.1 admin API responses for the example configuration
(`example/idp.sexp`): decoding them gives exactly its declaration. Written
from v2.19.1's DTOs and checked field for field against a real instance's
responses (`SERAI_IDP_CONTRACT=1 SERAI_IDP_CAPTURE=<dir> bash
tests/test_idp_contract.sh`). They add what a fresh instance lacks: a
federated identity, a secret's metadata, a CIMD client and grant.
