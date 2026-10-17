# Unbuilt Docling container recipe

This is a disconnected, disabled preparation unit. Docker/Podman is unavailable on the development host, so the image has **not** been built or started. No image was uploaded and no Cloudflare resource was provisioned. Do not mark Linux compatibility, filesystem isolation, retained-data deletion or production readiness as verified.

The recipe requires a separately reviewed **Python 3.12 Linux base image by SHA256 digest**, including the native shared libraries required by Docling/PyTorch. No base digest is selected here. An empty build argument intentionally prevents accidental builds. `RUN` installation is network-disabled; model acquisition and dependency acquisition never happen during serving.

An operator must separately prepare the ignored `provisioned/` folder with:

- `requirements-linux.lock.txt`: every transitive Linux dependency pinned and hashed, including Docling 2.139.0 and regex 2026.9.29. Do not copy the macOS freeze from tools/docling as a Linux hash lock. Audit dependency/model licenses and vulnerabilities before provisioning.
- `wheels/*.whl`: complete compatible Linux wheel set matching those hashes. Source builds and package-index fallback are forbidden by pip flags. Native shared libraries must already be in the reviewed base.
- `models/`: the previously checked layout/table artifacts with `studiquo-artifacts.json`. Startup rechecks its hashes/profile; the inventory is integrity evidence, not proof of model provenance or license approval.

Use the repository root as build context and this file's adjacent `Dockerfile.dockerignore`, which allows only fixed processor/tool sources and the explicit provisioning inputs. Review the resulting build context before using a remote builder. Never place documents, credentials, `.env`, user PDFs, personal data or keys in provisioning. Provisioning is ignored by Git.

The runtime runs as UID/GID 10001. Code/runtime/models are root-owned, readable and non-writable by that user. Only the private job root is owned by the serving user. The entrypoint verifies fixed installation and model inventory, performs bounded no-follow orphan cleanup, then binds the explicitly container-only `0.0.0.0:8080` listener. The original local adapter still binds loopback. The network listener is **not authentication**: do not publish this port.

The Worker controls startup with outbound Internet disabled and fixed image/size from configuration, verifies readiness without sending a PDF, sends parse once, and destroys the container before returning success. The VM size and max_instances are resource settings, **not a monetary spending cap**. Caller-side budget admission and raw-PDF consent are still required. VM egress, ingress Host/framing, native memory pressure, signal cancellation, destroy/reset and orphan cleanup require real Linux/Cloudflare tests before any enablement.

The default-policy sample in `../docling-worker/wrangler.example.jsonc` matches the currently installed Wrangler schema. The newer `durable_object` policy is not in that installed schema, so this unit deliberately does not mix its `images` startup API with default scheduling. No SDK or Wrangler package was updated. Do not combine the sample's legacy `migrations` with `exports`.

Rollback while disconnected: leave the execution flag false, keep the existing Worker unbound, and do not build/deploy this sample. After future connection, disable new admission first while retaining cancel/alarm cleanup. Never revert to a version that removes those cleanup guards.

References: [direct Container API](https://developers.cloudflare.com/containers/api/durable-object-container/), [configuration](https://developers.cloudflare.com/containers/configuration/wrangler/), [Docker context](https://docs.docker.com/build/concepts/context/#dockerignore-files), [pip hash installs](https://pip.pypa.io/en/stable/topics/secure-installs/).
