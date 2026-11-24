# Kockpit feature flipping & dyna-config: startup race and scheduler starvation

How to consume Kockpit **feature-flipping** and **dyna-config** from a Spring Boot application so that a
value published from the console is honoured **from the first unit of work** and **within one polling
period**, not "eventually".

Worked example: `communaute-traitement` and `communaute-notification` (domain `communautes`), Kockpit
`1.2.0`, Spring Boot `4.1`, Azure storage account transport.

---

## TL;DR

| Problem | Symptom | Fix |
|---|---|---|
| **Startup race**: the first Kockpit poll is asynchronous | A fresh instance (deploy, scale-out, crash restart) runs one batch with the *local default* even though the flag is OFF in Kockpit | Load the published state **synchronously** before exposing the flag client |
| **Scheduler starvation**: Kockpit's `MessagePoller` shares Spring's `TaskScheduler`, which has **1 thread** by default | A flag switched OFF only takes effect after the current batch (minutes, up to hours) | `spring.task.scheduling.pool.size` ≥ number of scheduled tasks |
| A flag is only evaluated when a batch starts | The batch in progress always runs to completion | Re-check the flag per item if a hard stop is required |

---

## 1. How the values reach the application

```
Kockpit console ──PUT──▶ Kockpit backend ──publish──▶ storage (blob / S3 / filesystem)
                                                        <domain>/<env>/<appId>/feature-flipping/<key>.json
                                                        <domain>/<env>/<appId>/dyna-config/<key>.json
                                                                   │
                         MessagePollingAutoConfiguration           │ list + read, every
                         one MessagePoller per ServiceDefinition ◀─┘ kockpit.communication.poller.scheduling
                                   │
                                   ▼  onMessage(Message) for every OnMessageListener bean
                         KockpitFlags (OnMessageListener + OpenFeature FeatureProvider)
                                   │  published value, else fallback to the Spring property
                                   ▼
                         OpenFeature Client ──▶ @Scheduled workers (inbox poller, notification poller…)
```

Key facts about the Kockpit SDK (`kockpit-core-communication-polling`):

- `MessagePollingAutoConfiguration` starts one `MessagePoller` per `ServiceDefinition` bean
  (`feature-flipping`, `dyna-config`) with `taskScheduler.schedule(..., new PeriodicTrigger(period))`.
- The poller uses **the application's `TaskScheduler` bean**, the same one that runs `@Scheduled` methods.
- Each pass re-reads **every** message of the service, oldest first: the last value wins and the full
  state is rebuilt after a restart. Messages are delivered to **every** `OnMessageListener` bean.
- Nothing signals "first pass completed". Until it completes, the application only knows its local
  defaults.

---

## 2. Problem 1: the startup race

### What happens

On startup, two things are scheduled at roughly the same time:

1. the Kockpit `MessagePoller` (first run immediately, but **asynchronous**: list blobs, download,
   parse; ~0.5–2 s against Azure storage);
2. the application's own `@Scheduled` worker (e.g. `InboxPoller`, `fixedDelay = PT5S`).

If the worker runs before the first Kockpit pass has been applied, the flag evaluates to the **local
fallback**:

```java
boolean actif = featureFlags.getBooleanValue("communaute.traitement.poller.actif", true); // Spring default: true
```

Kockpit says `false`, but the new instance reserves and processes a batch. Every deployment, scale-out
or crash-restart opens this window again, which is exactly when operators rely on a kill switch.

### Fix: a blocking initial load before the flag client exists

Read the published state **with the same `Consumer` beans the SDK uses** while the flag provider bean is
being created. The OpenFeature `Client` depends on that bean, and the workers depend on the `Client`,
so Spring cannot start a worker before the state is loaded.

```java
// KockpitFlags (OnMessageListener + FeatureProvider)
public void chargerEtatInitial(List<Consumer> consumers, String domain, String env, String appId) {
    for (Consumer consumer : consumers) {
        for (String service : SERVICES) {               // "feature-flipping", "dyna-config"
            try {
                consumer.poll(domain, env, appId, service).forEach(this::onMessage);
            } catch (RuntimeException e) {
                LOG.warn("Initial Kockpit load of {} failed ({}): Spring properties until the next poll",
                        service, e.toString());
            }
        }
    }
}
```

```java
// FeatureFlippingConfig
@Bean
@ConditionalOnProperty(value = "kockpit.feature-flipping.enabled", havingValue = "true")
public KockpitFlags kockpitFlags(Environment environment, ObjectProvider<Consumer> consumers) {
    KockpitFlags flags = new KockpitFlags(new EnvironmentSpringProvider(environment));
    // Before featureFlags (which depends on this bean), hence before any worker pass.
    flags.chargerEtatInitial(consumers.orderedStream().toList(),
            environment.getProperty("kockpit.domain"),
            environment.getProperty("kockpit.env"),
            environment.getProperty("kockpit.appId"));
    return flags;
}

@Bean
public Client featureFlags(Environment environment, ObjectProvider<KockpitFlags> kockpitFlags) {
    FeatureProvider provider = Optional.<FeatureProvider>ofNullable(kockpitFlags.getIfAvailable())
            .orElseGet(() -> new EnvironmentSpringProvider(environment));
    OpenFeatureAPI api = OpenFeatureAPI.getInstance();
    api.setProviderAndWait(DOMAIN, provider);
    return api.getClient(DOMAIN);
}
```

Design choices:

- **Same read path as the poller** (`Consumer.poll(domain, env, appId, service)`): same storage, same
  prefix, same ordering. There's no second source of truth, and the regular poller takes over afterwards.
  Re-applying the same messages is idempotent, and only real transitions are logged.
- **Fail open on the transport, not on the flag.** If storage is unreachable at startup, the app logs a
  WARN and starts on the Spring property, as before the fix, and the poller keeps retrying. Refusing to
  start would make the application's availability depend on Kockpit's. If your kill switch must fail
  *closed*, set the **Spring default** to the safe value (`false`) instead.
- **`ObjectProvider<Consumer>`**: no consumer bean (transport disabled, tests) means an empty list and
  no initial load.

---

## 3. Problem 2: scheduler starvation

### What happens

Spring Boot's auto-configured `ThreadPoolTaskScheduler` has **one thread** (`spring.task.scheduling.pool.size`
defaults to 1). Kockpit's `MessagePoller`s are scheduled on it, next to the application's `@Scheduled`
methods.

`communaute-traitement` processes up to 50 inbox entries per pass, each calling a Vertex AI agent
(timeout 180 s). While that pass runs:

- **no Kockpit poll runs**, so a flag switched OFF in the console isn't even *read*;
- the Kockpit poll, once it runs, blocks the inbox in turn (listing and downloading blobs).

Worst case latency of a kill switch: `batch size × per-item duration` (50 × 180 s = 2.5 h).

### Fix: one thread per scheduled task

```yaml
spring:
  task:
    scheduling:
      pool:
        size: 3   # inbox poller + Kockpit feature-flipping poller + Kockpit dyna-config poller
```

- `@Scheduled(fixedDelay = …)` never overlaps itself, whatever the pool size, so raising the pool
  doesn't run two batches in parallel.
- Count **every** periodic task: one `MessagePoller` per Kockpit `ServiceDefinition` bean
  (feature-flipping, dyna-config, …) plus your own `@Scheduled` methods.
- Don't declare your own `TaskScheduler` bean to isolate a long-running worker. Spring Boot backs off
  its auto-configured scheduler, and both the Kockpit pollers and `@Scheduled` end up on yours. Give
  long work its own `ScheduledExecutorService` instead (as `CanaryWorker` does).

---

## 4. What remains true after the fix

- **A flag is evaluated once per batch.** Switching `poller.actif` OFF stops the *next* batch. The batch
  in progress (up to `taille-lot` items) completes. If you need a hard stop, evaluate the flag per item.
  It's a map lookup, so it costs nothing.
- **Kill switch ≠ everything stops.** In `InboxPoller`, entries *forced* from the back-office are still
  processed while suspended (`reserverLotForce`).
- **Deleting a blob doesn't reset a flag** in a running application. Only a published `null` value
  removes it, otherwise the value disappears at the next restart.

---

## 5. Other pitfalls found during the same incident

Kockpit had **never** been effective in production. Each of these issues alone was enough to hide it.

| Layer | Pitfall | How it showed | Fix / rule |
|---|---|---|---|
| Secret | Storage account key stored with a `%` and a trailing newline (hand-pasted) | `IllegalArgumentException: Illegal base64 character 25` on **every** poll, at `StorageSharedKeyCredential.generateAuthorizationHeader` | Let Terraform write the key from the provider (`primary_access_key`); never `echo … \| secrets versions add` |
| Secret Manager | `latest` resolves to the newest version **even when disabled** | New Cloud Run revisions refused: `Secret Version […/versions/2] is in DISABLED state` | Add a newer **valid** version, don't just disable the bad one |
| Kockpit backend < 1.2.0 | After a backend restart, flags were cached with `enabled = null` | Console showed **manifest defaults** after reload | Backend ≥ 1.2.0 (`412fb5cd`) |
| API gateway (APIM) | Only the `PUT` operations were declared; `GET /{domain}/{env}/feature-flipping/{id}` and `/dyna-config/{id}` (and `POST …/_sync`) returned 404 | Console saves fine, but **every reload shows the manifest values**; Sync button does nothing | Declare every route the console calls in the gateway's OpenAPI |
| Manifest | Manifest default ≠ application default (`poller.actif`: manifest `false`, app `true`) | Console says OFF while the app runs | Keep manifest defaults equal to the application's Spring defaults |
| Feature-flipping acks | Custom listener publishes no `ack` | Console "instances" column stays empty, no proof a value was applied | Use the app logs (below) or publish acks like `FeatureFlippingClient` |

**Rule of thumb: trust the application's logs, not the console.** The console shows what the backend
returns, or the manifest when that call fails. The application shows what it applied.

---

## 6. Verifying in production

On every instance, shortly after startup and on every change:

```
Flag Kockpit communaute.traitement.poller.actif : null -> true      # initial load / first poll
Flag Kockpit communaute.traitement.poller.actif : true -> false     # change published from the console
communaute.traitement.poller.actif=false : traitement de l'inbox suspendu
Flag Kockpit communaute.traitement.canary.pourcentage : null -> 100 # dyna-config
```

Red flags:

- `Start feature-flipping for domain …` with **no** `Flag Kockpit … null -> …` afterwards: nothing is
  being read (transport error, wrong `appId`, or nothing published).
- `Illegal base64 character`, `AuthenticationFailed`, `Error reading blob`: transport or credential
  problem.
- `Chargement initial Kockpit … impossible`: the instance started on local defaults.

Cloud Logging query (GCP worker pools):

```bash
gcloud logging read 'resource.labels.worker_pool_name="communaute-traitement-pro"
  AND (textPayload:"Flag Kockpit" OR textPayload:"Chargement initial Kockpit"
       OR textPayload:"suspendu" OR textPayload:"Illegal base64")' \
  --project <project> --freshness=1h --limit 50
```

Read the published value directly (the source of truth):

```bash
az storage blob download --account-name kockpitreferential<env> --container-name referential<env> \
  --account-key "$KEY" -f /dev/stdout -o none \
  --name "<domain>/<env>/<appId>/feature-flipping/<key>.json"
```

---

## 7. Suggestions for the Kockpit SDK

The application-side fix works, but every consumer must rediscover it. Candidates for the SDK:

1. **Initial synchronous poll** in `MessagePollingAutoConfiguration` (opt-in property, e.g.
   `kockpit.communication.poller.initial-load: true`), or a "first pass completed" event / readiness
   indicator that applications can wait on.
2. **A dedicated scheduler** for `MessagePoller`s instead of the application's `TaskScheduler`, so
   pollers can't starve or be starved by business tasks.
3. **Server-side prefix listing** in `StorageAccountConsumer` (`listBlobs(new ListBlobsOptions().setPrefix(…))`):
   today the whole container is listed on every pass, for every service, and filtered client-side.
4. **Document the console/manifest contract**: a missing backend value is displayed as the manifest
   default, so manifest defaults should match application defaults.

---

## Files changed (communautes)

- `communaute-traitement/…/flag/KockpitFlags.java`, `FeatureFlippingConfig.java`: initial load
  (feature-flipping + dyna-config)
- `communaute-notification/…/flag/KockpitFlags.java`, `FeatureFlippingConfig.java`: initial load
  (feature-flipping)
- `communaute-traitement/src/main/resources/application.yaml`: `spring.task.scheduling.pool.size: 3`
- `communaute-notification/src/main/resources/application.yaml`: `spring.task.scheduling.pool.size: 2`
- Tests: `KockpitFlagsTest` (initial load applied; storage failure doesn't block startup),
  `FeatureFlippingKockpitContexteTest` (value served at startup, without any poll)
