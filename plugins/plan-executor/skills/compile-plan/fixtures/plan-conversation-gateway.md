# Conversation Gateway Non-Public API Implementation Plan

**Goal:** Implement the non-public API surface on `conversation-gateway` (V1–V7 verbs, `conversation.started` webhook) per the design spec. Hides NATS entirely from non-CP consumers. REST + SSE + webhooks.
**Type:** Feature
**JIRA:** CPL-000
**Tech Stack:** NestJS 11, @parloa/toolkit, @parloa/ts-redis, @parloa/lib-message-bus, true-myth, rxjs, Jest + Testcontainers
**Code Standards:** n/a
**Status:** READY
**no-worktree:** [ ]
**no-pr:** [ ]
**draft-pr:** [x]
**merge:** [ ]
**merge-admin:** [ ]
**non-interactive:** [x]
**execution:** remote
**add-marketplaces:** anthropics/claude-plugins-official, parloa/claudes-kitchen, JuliusBrussee/caveman, andreas-pohl-parloa/my-coding, andreas-pohl-parloa/plan-executor-plugin, parloa/inline-discussion
**add-plugins:** backend-services@claudes-kitchen, career-development@claudes-kitchen, caveman@caveman, gateway@claudes-kitchen, go-services@claudes-kitchen, inline-discussion@inline-discussion, my@my-coding, operational-excellence@claudes-kitchen, parloa-toolkit-services@claudes-kitchen, plan-executor@plan-executor, playwright@claude-plugins-official, python-services@claudes-kitchen, rust-services@claudes-kitchen, security@claudes-kitchen, skills-development@claudes-kitchen, superpowers@claude-plugins-official, threat-modeling@claudes-kitchen, typescript-services@claudes-kitchen, workflows@claudes-kitchen

---


## File Map

### Files to Create

**Domain — conversation-bus:**
- `src/domain/conversation-bus/entities/ids.entity.ts` — branded `ConversationId`, `ParticipantId`, `LegId`, `TenantId`, `EventId` + constructors
- `src/domain/conversation-bus/entities/non-public-event.entity.ts` — `NonPublicEvent` type + `createNonPublicEvent` factory
- `src/domain/conversation-bus/entities/observe-scope.entity.ts` — `ObserveScope` discriminated union
- `src/domain/conversation-bus/entities/participant-leg-target.entity.ts` — `ParticipantLegTarget` type
- `src/domain/conversation-bus/errors/conversation-bus.error.ts` — `ConversationBusError`, `EventTypeNotAllowedError`, `UnknownEventTypeError`, `TranslationError`
- `src/domain/conversation-bus/ports/conversation-bus.port.ts` — `ConversationBusPort` interface + `CONVERSATION_BUS` token
- `src/domain/conversation-bus/index.ts` — barrel
- `src/domain/conversation-bus/conversation-bus.domain.module.ts` — empty NestJS module

**Domain — webhook:**
- `src/domain/webhook/entities/webhook-registration.entity.ts` — `WebhookRegistration` + `WebhookId` + `createWebhookRegistration`
- `src/domain/webhook/entities/dispatch-result.entity.ts` — `DispatchResult` discriminated union
- `src/domain/webhook/errors/webhook.error.ts` — `WebhookRegistrationError`, `WebhookNotFoundError`, `DuplicateWebhookError`, `WebhookDispatchError`
- `src/domain/webhook/ports/webhook-registration-repository.port.ts` — `WebhookRegistrationRepository` + `WEBHOOK_REGISTRATION_REPOSITORY` token
- `src/domain/webhook/ports/webhook-dispatcher.port.ts` — `WebhookDispatcherPort` + `WEBHOOK_DISPATCHER` token
- `src/domain/webhook/index.ts` — barrel
- `src/domain/webhook/webhook.domain.module.ts` — empty NestJS module

**Service — conversation-bus (pure, no infra):**
- `src/service/conversation-bus/event-type-map.ts` — `INTERNAL_TO_NONPUBLIC`, `NONPUBLIC_TO_INTERNAL`, verb allowlists, critical-event set, `ALLOWED_PAYLOAD_FIELDS`
- `src/service/conversation-bus/event-translation.service.ts` — `EventTranslationService` (in/out directions, allowlist-based)
- `src/service/conversation-bus/conversation-bus.service.module.ts` — NestJS module exporting `EventTranslationService`

**Service — webhook:**
- `src/service/webhook/webhook-dispatch.service.ts` — listens to `subscribeToConversationStarted`, fans out registrations, triggers termination on failure
- `src/service/webhook/webhook.service.module.ts` — NestJS module

**Outbound — conversation-bus (owns all NATS concepts):**
- `src/outbound/conversation-bus/nats/subject-templates.ts` — pure functions returning subject strings, stream/durable constants (`CP_CONTROL_STREAMS`, `CP_CONTROL_DURABLE`, `TERMINATION_SUBJECT`)
- `src/outbound/conversation-bus/nats/conversation-bus-nats.adapter.ts` — `ConversationBusNatsAdapter` implementing `ConversationBusPort`
- `src/outbound/conversation-bus/nats/conversation-bus.outbound.module.ts`

**Outbound — webhook:**
- `src/outbound/webhook/redis/webhook-registration.redis.adapter.ts` — `WebhookRegistrationRedisRepository`
- `src/outbound/webhook/redis/webhook-registration.outbound.module.ts`
- `src/outbound/webhook/http/webhook-http-dispatcher.adapter.ts` — `WebhookHttpDispatcher`
- `src/outbound/webhook/http/webhook-http-dispatcher.outbound.module.ts`

**Inbound — conversation-bus:**
- `src/inbound/conversation-bus/dto/publish-event.dto.ts` — request DTOs (class-validator)
- `src/inbound/conversation-bus/dto/non-public-event.dto.ts` — shared envelope DTO
- `src/inbound/conversation-bus/conversation-bus.controller.ts` — V1/V2/V3 POST + V5 SSE
- `src/inbound/conversation-bus/conversation-observe.controller.ts` — V4 SSE (3 scopes)
- `src/inbound/conversation-bus/sse-streamer.ts` — rxjs → `text/event-stream` helper with buffer + critical-event overflow logic
- `src/inbound/conversation-bus/error-mapper.ts` — domain-error → HTTP-problem mapping
- `src/inbound/conversation-bus/conversation-bus.inbound.module.ts`

**Inbound — webhook:**
- `src/inbound/webhook/dto/webhook-registration.dto.ts` — request/response DTOs
- `src/inbound/webhook/webhook.controller.ts` — V7a/V7b/V7c
- `src/inbound/webhook/webhook.inbound.module.ts`

**App-level:**
- Modify `src/app.module.ts` — add env schema keys, wire new modules, add metrics
- Modify `src/inbound/inbound.module.ts` — import new inbound modules

**Tests (mirroring `src/` under `test/`):**
- `test/domain/conversation-bus/*.spec.ts`
- `test/domain/webhook/*.spec.ts`
- `test/service/conversation-bus/*.spec.ts`
- `test/service/webhook/*.spec.ts`
- `test/outbound/conversation-bus/nats/*.integration-spec.ts`
- `test/outbound/webhook/redis/*.integration-spec.ts`
- `test/outbound/webhook/http/*.integration-spec.ts`
- `test/inbound/conversation-bus/*.spec.ts`
- `test/inbound/webhook/*.spec.ts`
- `test/e2e/conversation-bus.e2e-spec.ts`
- `test/e2e/webhook-dispatch.e2e-spec.ts`

---

## Phase 0 — Security & trust-boundary baseline

This phase delivers three primitives that later phases depend on:
- **`TenantGuard`** — NestJS guard that reads a trusted `X-Tenant-Id` header (ingress-injected), attaches it to the request, and rejects requests with a missing/malformed header. Used on every inbound controller (V1–V7).
- **`SafeUrlValidator`** — SSRF-safe URL validator: enforces allowed schemes, blocks private/loopback/link-local IPs, resolves DNS once and pins the IP.
- **Per-`event_type` publish DTOs** — a discriminated union of class-validator DTOs with `@ValidateNested` + `@Type` + `forbidNonWhitelisted: true`, matching the OpenAPI `oneOf`/`discriminator` contract so inbound `data` cannot carry unknown fields.

### Task 0.1: `TenantGuard` + header constant

**Files:**
- Create: `src/inbound/shared/tenant-context.ts` — header name constant + request-context helper
- Create: `src/inbound/shared/tenant.guard.ts` — NestJS guard
- Create: `src/inbound/shared/tenant-scoped.decorator.ts` — param decorator `@TenantId()`
- Test: `test/inbound/shared/tenant.guard.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/inbound/shared/tenant.guard.spec.ts
import { ExecutionContext, ForbiddenException } from '@nestjs/common'
import { TenantGuard } from '~/inbound/shared/tenant.guard'

const ctx = (headers: Record<string, string>): ExecutionContext => ({
  switchToHttp: () => ({ getRequest: () => ({ headers }) }),
}) as never

describe('TenantGuard', () => {
  const guard = new TenantGuard()

  it('attaches tenant_id to req when header is well-formed', () => {
    const req: any = { headers: { 'x-tenant-id': 't1' } }
    const c: ExecutionContext = { switchToHttp: () => ({ getRequest: () => req }) } as never
    expect(guard.canActivate(c)).toBe(true)
    expect(req.tenant_id).toBe('t1')
  })
  it('rejects missing header', () => {
    expect(() => guard.canActivate(ctx({}))).toThrow(ForbiddenException)
  })
  it('rejects malformed header (not matching id regex)', () => {
    expect(() => guard.canActivate(ctx({ 'x-tenant-id': 'bad id\n' }))).toThrow(ForbiddenException)
  })
  it('rejects too-long header', () => {
    expect(() => guard.canActivate(ctx({ 'x-tenant-id': 'a'.repeat(200) }))).toThrow(ForbiddenException)
  })
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/inbound/shared/tenant-context.ts
export const TENANT_HEADER = 'x-tenant-id'
export const TENANT_ID_REGEX = /^[A-Za-z0-9_-]{1,128}$/
```

```typescript
// src/inbound/shared/tenant.guard.ts
import { CanActivate, ExecutionContext, ForbiddenException, Injectable } from '@nestjs/common'
import { TENANT_HEADER, TENANT_ID_REGEX } from './tenant-context'

@Injectable()
export class TenantGuard implements CanActivate {
  canActivate(context: ExecutionContext): boolean {
    const req = context.switchToHttp().getRequest<{ headers: Record<string, unknown>; tenant_id?: string }>()
    const raw = req.headers[TENANT_HEADER]
    const value = Array.isArray(raw) ? raw[0] : raw
    if (typeof value !== 'string' || !TENANT_ID_REGEX.test(value)) {
      throw new ForbiddenException({
        type: 'about:blank',
        title: 'TenantHeaderMissingOrInvalid',
        status: 403,
        code: 'tenant_header_missing_or_invalid',
      })
    }
    req.tenant_id = value
    return true
  }
}
```

```typescript
// src/inbound/shared/tenant-scoped.decorator.ts
import { createParamDecorator, ExecutionContext } from '@nestjs/common'
export const TenantId = createParamDecorator(
  (_: unknown, ctx: ExecutionContext): string =>
    ctx.switchToHttp().getRequest<{ tenant_id: string }>().tenant_id,
)
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/inbound/shared test/inbound/shared
git commit -m "feat(CPL-000): add TenantGuard + @TenantId() decorator for tenant-bound inbound"
```

### Task 0.2: SSRF-safe URL validator

**Files:**
- Create: `src/outbound/webhook/http/safe-url.validator.ts`
- Test: `test/outbound/webhook/http/safe-url.validator.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/outbound/webhook/http/safe-url.validator.spec.ts
import { assertSafeHttpUrl, resolveToSafeTarget } from '~/outbound/webhook/http/safe-url.validator'

describe('assertSafeHttpUrl', () => {
  it.each([
    ['http://169.254.169.254/latest/meta-data/', 'loopback_or_private'],
    ['http://127.0.0.1:6379',                    'loopback_or_private'],
    ['http://localhost/hook',                    'loopback_or_private'],
    ['http://10.0.0.1/hook',                     'loopback_or_private'],
    ['http://[::1]/hook',                        'loopback_or_private'],
    ['ftp://svc.internal.parloa.com/hook',       'scheme_not_allowed'],
    ['https://user:pass@svc.internal.parloa.com/hook', 'userinfo_not_allowed'],
    ['not-a-url',                                'invalid_url'],
  ])('rejects %s as %s', (url, code) => {
    const r = assertSafeHttpUrl(url, { allowedSchemes: ['https'], allowedHostSuffixes: ['.internal.parloa.com'] })
    expect(r.isErr).toBe(true)
    expect(r.unwrapErr().code).toBe(code)
  })

  it('accepts allowed-suffix https URL', () => {
    const r = assertSafeHttpUrl('https://svc.internal.parloa.com/hook',
      { allowedSchemes: ['https'], allowedHostSuffixes: ['.internal.parloa.com'] })
    expect(r.isOk).toBe(true)
  })

  it('rejects URL whose hostname resolves to private IP even when suffix matches (rebinding)', async () => {
    // integration-style check using the exported resolver; unit suite injects a fake resolver
    const fakeResolve = async () => '192.168.0.1'
    const r = await resolveToSafeTarget('https://svc.internal.parloa.com/hook',
      { allowedSchemes: ['https'], allowedHostSuffixes: ['.internal.parloa.com'], resolve: fakeResolve })
    expect(r.isErr).toBe(true)
    expect(r.unwrapErr().code).toBe('resolved_to_private_ip')
  })
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/outbound/webhook/http/safe-url.validator.ts
import { Result } from 'true-myth'
import dns from 'node:dns/promises'

export type SafeUrlError = Readonly<{ code:
  | 'invalid_url'
  | 'scheme_not_allowed'
  | 'userinfo_not_allowed'
  | 'host_suffix_not_allowed'
  | 'loopback_or_private'
  | 'resolved_to_private_ip'
  readonly message: string }>

export type SafeUrlOptions = Readonly<{
  allowedSchemes:      ReadonlyArray<string>           // e.g. ['https']
  allowedHostSuffixes: ReadonlyArray<string>           // e.g. ['.internal.parloa.com']
  resolve?:            (host: string) => Promise<string>  // DI for tests
}>

const PRIVATE_REGEX =
  /^(127\.|10\.|192\.168\.|169\.254\.|::1|fc[0-9a-f]{2}:|fe80:|0\.0\.0\.0)|^localhost$/i
const PRIVATE_V4_172 = /^172\.(1[6-9]|2[0-9]|3[0-1])\./

const isPrivateHost = (h: string) =>
  PRIVATE_REGEX.test(h) || PRIVATE_V4_172.test(h) || h.toLowerCase() === 'localhost'

export const assertSafeHttpUrl = (
  raw: string,
  opts: SafeUrlOptions,
): Result<URL, SafeUrlError> => {
  let url: URL
  try { url = new URL(raw) } catch { return Result.err({ code: 'invalid_url', message: 'not a valid URL' }) }
  if (!opts.allowedSchemes.includes(url.protocol.replace(':', '')))
    return Result.err({ code: 'scheme_not_allowed', message: `scheme ${url.protocol} not allowed` })
  if (url.username || url.password)
    return Result.err({ code: 'userinfo_not_allowed', message: 'userinfo in URL is not allowed' })
  if (isPrivateHost(url.hostname))
    return Result.err({ code: 'loopback_or_private', message: `host ${url.hostname} is private/loopback` })
  const suffixOk = opts.allowedHostSuffixes.some(s => url.hostname.endsWith(s))
  if (!suffixOk)
    return Result.err({ code: 'host_suffix_not_allowed', message: `host ${url.hostname} not in allowlist` })
  return Result.ok(url)
}

export const resolveToSafeTarget = async (
  raw: string,
  opts: SafeUrlOptions,
): Promise<Result<{ url: URL; pinnedIp: string }, SafeUrlError>> => {
  const validated = assertSafeHttpUrl(raw, opts)
  if (validated.isErr) return validated as never
  const url = validated.unwrapOr(null as never)
  const resolver = opts.resolve ?? (async (h: string) => (await dns.lookup(h)).address)
  const ip = await resolver(url.hostname)
  if (isPrivateHost(ip))
    return Result.err({ code: 'resolved_to_private_ip', message: `resolved to private IP ${ip}` })
  return Result.ok({ url, pinnedIp: ip })
}
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/outbound/webhook/http/safe-url.validator.ts \
        test/outbound/webhook/http/safe-url.validator.spec.ts
git commit -m "feat(CPL-000): add SSRF-safe URL validator for webhook endpoints"
```

### Task 0.3: Per-`event_type` publish DTOs (discriminated)

**Files:**
- Create: `src/inbound/conversation-bus/dto/event-data.dto.ts` — per-event-type `data` classes with `additionalProperties: false` semantics (`forbidNonWhitelisted: true` on the ValidationPipe + `@Allow()`-free fields)
- Create: `src/inbound/conversation-bus/dto/discriminated-event.dto.ts` — base envelope + `@Type(() => …, { discriminator: … })`
- Test: `test/inbound/conversation-bus/dto/discriminated-event.dto.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/inbound/conversation-bus/dto/discriminated-event.dto.spec.ts
import { validate } from 'class-validator'
import { plainToInstance } from 'class-transformer'
import {
  MessageUserPublishDto,
  MessageAgentPublishDto,
  ConversationTerminationRequestedPublishDto,
} from '~/inbound/conversation-bus/dto/discriminated-event.dto'

const base = (event_type: string) => ({
  event_id: 'e1', event_type, conversation_id: 'c1', tenant_id: 't1',
  timestamp: 1, version: '1',
})

it('rejects unknown field on data (additionalProperties: false)', async () => {
  const dto = plainToInstance(MessageUserPublishDto, {
    ...base('message.user'),
    data: { text: 'hi', malicious: 'x' },
  })
  const errors = await validate(dto, { whitelist: true, forbidNonWhitelisted: true })
  expect(errors.length).toBeGreaterThan(0)
})

it('accepts a valid message.user', async () => {
  const dto = plainToInstance(MessageUserPublishDto, {
    ...base('message.user'),
    data: { text: 'hi' },
  })
  const errors = await validate(dto, { whitelist: true, forbidNonWhitelisted: true })
  expect(errors).toEqual([])
})

it('accepts a valid conversation.termination-requested', async () => {
  const dto = plainToInstance(ConversationTerminationRequestedPublishDto, {
    ...base('conversation.termination-requested'),
    data: { reason: 'agent_requested', leg_id: 'l1', direction: 'outbound' },
  })
  const errors = await validate(dto, { whitelist: true, forbidNonWhitelisted: true })
  expect(errors).toEqual([])
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/inbound/conversation-bus/dto/event-data.dto.ts
import { Equals, IsIn, IsOptional, IsString, Length, Matches } from 'class-validator'
import { ApiProperty } from '@nestjs/swagger'

const LEG_REGEX = /^[A-Za-z0-9_-]{1,128}$/

export class MessageUserDataDto {
  @ApiProperty() @IsString() @Length(1, 8192) text!: string
  @ApiProperty({ required: false }) @IsOptional() @Matches(LEG_REGEX) leg_id?: string
  @ApiProperty({ required: false }) @IsOptional() @IsIn(['inbound', 'outbound']) direction?: 'inbound' | 'outbound'
}

export class MessageAgentDataDto {
  @ApiProperty() @IsString() @Length(1, 8192) text!: string
  @ApiProperty({ required: false }) @IsOptional() @Matches(LEG_REGEX) leg_id?: string
  @ApiProperty({ required: false }) @IsOptional() @IsIn(['inbound', 'outbound']) direction?: 'inbound' | 'outbound'
}

export class PingFrameDataDto {
  @ApiProperty() @Matches(LEG_REGEX) leg_id!: string
  @ApiProperty() @IsIn(['inbound', 'outbound']) direction!: 'inbound' | 'outbound'
}

export class PongFrameDataDto {
  @ApiProperty() @Matches(LEG_REGEX) leg_id!: string
  @ApiProperty() @IsIn(['inbound', 'outbound']) direction!: 'inbound' | 'outbound'
}

export class ConversationTerminationRequestedDataDto {
  @ApiProperty() @IsIn(['agent_requested', 'user_inactivity_timeout']) reason!: string
  @ApiProperty() @Matches(LEG_REGEX) leg_id!: string
  @ApiProperty() @IsIn(['inbound', 'outbound']) direction!: 'inbound' | 'outbound'
}

export class AddParticipantLegRequestedDataDto {
  @ApiProperty({ required: false }) @IsOptional() @Matches(LEG_REGEX) participant_id?: string
  @ApiProperty() @IsString() @Length(1, 256) channel_config_id!: string
}
```

```typescript
// src/inbound/conversation-bus/dto/discriminated-event.dto.ts
import { Equals, IsInt, IsOptional, IsString, Matches, ValidateNested } from 'class-validator'
import { Type } from 'class-transformer'
import { ApiProperty } from '@nestjs/swagger'
import {
  MessageUserDataDto, MessageAgentDataDto, PingFrameDataDto, PongFrameDataDto,
  ConversationTerminationRequestedDataDto, AddParticipantLegRequestedDataDto,
} from './event-data.dto'

const ID_REGEX = /^[A-Za-z0-9_-]{1,128}$/

abstract class PublishBaseDto {
  @ApiProperty() @Matches(ID_REGEX) event_id!: string
  @ApiProperty() @Matches(ID_REGEX) conversation_id!: string
  @ApiProperty() @Matches(ID_REGEX) tenant_id!: string
  @ApiProperty({ required: false }) @IsOptional() @Matches(ID_REGEX) participant_id?: string
  @ApiProperty({ required: false }) @IsOptional() @Matches(ID_REGEX) leg_id?: string
  @ApiProperty() @IsInt() timestamp!: number
  @ApiProperty() @Equals('1') version!: '1'
  @ApiProperty({ required: false }) @IsOptional() @Matches(ID_REGEX) correlation_id?: string
}

export class MessageUserPublishDto extends PublishBaseDto {
  @ApiProperty() @Equals('message.user') event_type!: 'message.user'
  @ApiProperty({ type: MessageUserDataDto }) @ValidateNested() @Type(() => MessageUserDataDto) data!: MessageUserDataDto
}
export class PingFramePublishDto extends PublishBaseDto {
  @ApiProperty() @Equals('ping.frame') event_type!: 'ping.frame'
  @ApiProperty({ type: PingFrameDataDto }) @ValidateNested() @Type(() => PingFrameDataDto) data!: PingFrameDataDto
}
export class MessageAgentPublishDto extends PublishBaseDto {
  @ApiProperty() @Equals('message.agent') event_type!: 'message.agent'
  @ApiProperty({ type: MessageAgentDataDto }) @ValidateNested() @Type(() => MessageAgentDataDto) data!: MessageAgentDataDto
}
export class PongFramePublishDto extends PublishBaseDto {
  @ApiProperty() @Equals('pong.frame') event_type!: 'pong.frame'
  @ApiProperty({ type: PongFrameDataDto }) @ValidateNested() @Type(() => PongFrameDataDto) data!: PongFrameDataDto
}
export class ConversationTerminationRequestedPublishDto extends PublishBaseDto {
  @ApiProperty() @Equals('conversation.termination-requested') event_type!: 'conversation.termination-requested'
  @ApiProperty({ type: ConversationTerminationRequestedDataDto }) @ValidateNested() @Type(() => ConversationTerminationRequestedDataDto) data!: ConversationTerminationRequestedDataDto
}
export class AddParticipantLegRequestedPublishDto extends PublishBaseDto {
  @ApiProperty() @Equals('participant.add-leg-requested') event_type!: 'participant.add-leg-requested'
  @ApiProperty({ type: AddParticipantLegRequestedDataDto }) @ValidateNested() @Type(() => AddParticipantLegRequestedDataDto) data!: AddParticipantLegRequestedDataDto
}

export type InputEventPublishDto  = MessageUserPublishDto | PingFramePublishDto
export type OutputEventPublishDto = MessageAgentPublishDto | PongFramePublishDto
export type ControlEventPublishDto =
  | ConversationTerminationRequestedPublishDto
  | AddParticipantLegRequestedPublishDto
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/inbound/conversation-bus/dto/event-data.dto.ts \
        src/inbound/conversation-bus/dto/discriminated-event.dto.ts \
        test/inbound/conversation-bus/dto/discriminated-event.dto.spec.ts
git commit -m "feat(CPL-000): add discriminated per-event-type publish DTOs with additionalProperties: false semantics"
```

### Task 0.4: Global ValidationPipe configured `forbidNonWhitelisted: true` + body-size caps

**Files:**
- Modify: `src/main.ts` (enable `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true })` globally, set body-parser JSON limit)

- [ ] **Step 1:** Add `app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true, transform: true }))` in bootstrap.
- [ ] **Step 2:** Configure `app.use(bodyParser.json({ limit: '64kb' }))` for publish routes and a tighter limit on `/v1/webhooks`.
- [ ] **Step 3: Commit**

```
git add src/main.ts
git commit -m "feat(CPL-000): enforce global additionalProperties: false and body-size caps"
```

---

## Phase 1 — Domain types, ports, errors

### Task 1.1: Error types + branded identity types

Merged to avoid a circular dep between the id constructors (which return `Result<_, MissingFieldError>`) and the error type they reference. Order: errors first, then ids, one combined TDD cycle.

**Files:**
- Create: `src/domain/conversation-bus/errors/conversation-bus.error.ts`
- Create: `src/domain/conversation-bus/entities/ids.entity.ts`
- Test: `test/domain/conversation-bus/conversation-bus.error.spec.ts`
- Test: `test/domain/conversation-bus/ids.entity.spec.ts`

- [ ] **Step 1: Write the failing tests**

```typescript
// test/domain/conversation-bus/conversation-bus.error.spec.ts
import {
  MissingFieldError,
  UnknownEventTypeError,
  EventTypeNotAllowedError,
  TranslationError,
  ConversationBusPublishError,
  ConversationBusObserveError,
} from '~/domain/conversation-bus/errors/conversation-bus.error'

describe('conversation-bus errors', () => {
  it('MissingFieldError carries field name', () => {
    expect(new MissingFieldError('conversation_id').field).toBe('conversation_id')
  })
  it('EventTypeNotAllowedError carries context', () => {
    const e = new EventTypeNotAllowedError('message.agent', 'input-events')
    expect(e.eventType).toBe('message.agent')
    expect(e.verb).toBe('input-events')
  })
})
```

```typescript
// test/domain/conversation-bus/ids.entity.spec.ts
import {
  makeConversationId,
  makeParticipantId,
  makeLegId,
  makeTenantId,
  makeEventId,
} from '~/domain/conversation-bus/entities/ids.entity'

describe('ids', () => {
  it('brands a non-empty string as ConversationId', () => {
    expect(makeConversationId('c1').unwrapOr('' as never)).toBe('c1')
  })
  it('rejects empty string', () => {
    expect(makeConversationId('').isErr).toBe(true)
  })
})
```

- [ ] **Step 2: Run tests** — FAIL (both).

- [ ] **Step 3: Implement errors first (no deps)**

```typescript
// src/domain/conversation-bus/errors/conversation-bus.error.ts
export class MissingFieldError extends Error {
  readonly field: string
  constructor(field: string) {
    super(`Missing required field: ${field}`)
    this.field = field
    this.name = 'MissingFieldError'
  }
}

export class UnknownEventTypeError extends Error {
  readonly eventType: string
  constructor(eventType: string) {
    super(`Unknown event_type: ${eventType}`)
    this.eventType = eventType
    this.name = 'UnknownEventTypeError'
  }
}

export class EventTypeNotAllowedError extends Error {
  readonly eventType: string
  readonly verb: string
  constructor(eventType: string, verb: string) {
    super(`event_type '${eventType}' is not allowed on verb '${verb}'`)
    this.eventType = eventType
    this.verb = verb
    this.name = 'EventTypeNotAllowedError'
  }
}

export class TranslationError extends Error {
  readonly reason: string
  constructor(reason: string) {
    super(`Translation failed: ${reason}`)
    this.reason = reason
    this.name = 'TranslationError'
  }
}

export class ConversationBusPublishError extends Error {
  readonly cause: unknown
  constructor(cause: unknown) {
    super(`Publish failed: ${cause instanceof Error ? cause.message : String(cause)}`)
    this.cause = cause
    this.name = 'ConversationBusPublishError'
  }
}

export class ConversationBusObserveError extends Error {
  readonly cause: unknown
  constructor(cause: unknown) {
    super(`Observe failed: ${cause instanceof Error ? cause.message : String(cause)}`)
    this.cause = cause
    this.name = 'ConversationBusObserveError'
  }
}

export type ConversationBusError =
  | MissingFieldError
  | UnknownEventTypeError
  | EventTypeNotAllowedError
  | TranslationError
  | ConversationBusPublishError
  | ConversationBusObserveError
```

- [ ] **Step 4: Implement branded ids (depends on `MissingFieldError`)**

```typescript
// src/domain/conversation-bus/entities/ids.entity.ts
import { Result } from 'true-myth'
import { MissingFieldError } from '~/domain/conversation-bus/errors/conversation-bus.error'

type Brand<K, T> = string & { readonly __brand: K }

export type ConversationId = Brand<'ConversationId', string>
export type ParticipantId  = Brand<'ParticipantId', string>
export type LegId          = Brand<'LegId', string>
export type TenantId       = Brand<'TenantId', string>
export type EventId        = Brand<'EventId', string>

const mk = <T extends string>(field: string) =>
  (v: string): Result<T, MissingFieldError> =>
    v.length === 0
      ? Result.err(new MissingFieldError(field))
      : Result.ok(v as T)

export const makeConversationId = mk<ConversationId>('conversation_id')
export const makeParticipantId  = mk<ParticipantId>('participant_id')
export const makeLegId          = mk<LegId>('leg_id')
export const makeTenantId       = mk<TenantId>('tenant_id')
export const makeEventId        = mk<EventId>('event_id')
```

- [ ] **Step 5: Run tests** — both PASS.
- [ ] **Step 6: Commit**

```
git add src/domain/conversation-bus/entities/ids.entity.ts \
        src/domain/conversation-bus/errors/conversation-bus.error.ts \
        test/domain/conversation-bus/ids.entity.spec.ts \
        test/domain/conversation-bus/conversation-bus.error.spec.ts
git commit -m "feat(CPL-000): add error types and branded ids for conversation-bus domain"
```

### Task 1.2: `NonPublicEvent` entity

**Files:**
- Create: `src/domain/conversation-bus/entities/non-public-event.entity.ts`
- Test: `test/domain/conversation-bus/non-public-event.entity.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// test/domain/conversation-bus/non-public-event.entity.spec.ts
import { Maybe, Result } from 'true-myth'
import { createNonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import { makeConversationId, makeTenantId, makeEventId } from '~/domain/conversation-bus/entities/ids.entity'

describe('createNonPublicEvent', () => {
  it('builds a frozen envelope with required fields', () => {
    const ev = createNonPublicEvent({
      event_id: makeEventId('e1').unwrapOr('' as never),
      event_type: 'message.agent',
      conversation_id: makeConversationId('c1').unwrapOr('' as never),
      tenant_id: makeTenantId('t1').unwrapOr('' as never),
      participant_id: Maybe.nothing(),
      leg_id: Maybe.nothing(),
      timestamp: 123,
      version: '1',
      correlation_id: Maybe.nothing(),
      data: { text: 'hi' },
    })
    expect(ev.isOk).toBe(true)
    expect(Object.isFrozen(ev.unwrapOr(null as never))).toBe(true)
  })
})
```

- [ ] **Step 2: Run test** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/domain/conversation-bus/entities/non-public-event.entity.ts
import { Maybe, Result } from 'true-myth'
import type { ConversationId, EventId, LegId, ParticipantId, TenantId } from '~/domain/conversation-bus/entities/ids.entity'

export type NonPublicEvent = Readonly<{
  event_id:        EventId
  event_type:      string
  conversation_id: ConversationId
  tenant_id:       TenantId
  participant_id:  Maybe<ParticipantId>
  leg_id:          Maybe<LegId>
  timestamp:       number
  version:         string
  correlation_id:  Maybe<string>
  data:            Readonly<Record<string, unknown>>
}>

export type NonPublicEventParams = NonPublicEvent

export const createNonPublicEvent = (params: NonPublicEventParams): Result<NonPublicEvent, never> =>
  Result.ok(Object.freeze({ ...params, data: Object.freeze({ ...params.data }) }))
```

- [ ] **Step 4: Run tests** — PASS.
- [ ] **Step 5: Commit**

```
git add src/domain/conversation-bus/entities/non-public-event.entity.ts \
        test/domain/conversation-bus/non-public-event.entity.spec.ts
git commit -m "feat(CPL-000): add NonPublicEvent entity"
```

### Task 1.3: `ObserveScope` + `ParticipantLegTarget`

**Files:**
- Create: `src/domain/conversation-bus/entities/observe-scope.entity.ts`
- Create: `src/domain/conversation-bus/entities/participant-leg-target.entity.ts`
- Test: `test/domain/conversation-bus/observe-scope.entity.spec.ts`

- [ ] **Step 1: Write the failing test**

```typescript
// test/domain/conversation-bus/observe-scope.entity.spec.ts
import { makeConversationId, makeParticipantId, makeLegId } from '~/domain/conversation-bus/entities/ids.entity'
import {
  conversationScope,
  participantScope,
  legScope,
} from '~/domain/conversation-bus/entities/observe-scope.entity'

describe('ObserveScope', () => {
  it('builds discriminated scopes', () => {
    const c = conversationScope(makeConversationId('c1').unwrapOr('' as never))
    expect(c.scope).toBe('conversation')
    const p = participantScope(
      makeConversationId('c1').unwrapOr('' as never),
      makeParticipantId('p1').unwrapOr('' as never),
    )
    expect(p.scope).toBe('participant')
    const l = legScope(
      makeConversationId('c1').unwrapOr('' as never),
      makeParticipantId('p1').unwrapOr('' as never),
      makeLegId('l1').unwrapOr('' as never),
    )
    expect(l.scope).toBe('leg')
  })
})
```

- [ ] **Step 2: Run test** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/domain/conversation-bus/entities/observe-scope.entity.ts
import type { ConversationId, LegId, ParticipantId } from '~/domain/conversation-bus/entities/ids.entity'

export type ObserveScope =
  | { readonly scope: 'conversation'; readonly conversation_id: ConversationId }
  | { readonly scope: 'participant';  readonly conversation_id: ConversationId; readonly participant_id: ParticipantId }
  | { readonly scope: 'leg';          readonly conversation_id: ConversationId; readonly participant_id: ParticipantId; readonly leg_id: LegId }

export const conversationScope = (conversation_id: ConversationId): ObserveScope =>
  Object.freeze({ scope: 'conversation', conversation_id })

export const participantScope = (
  conversation_id: ConversationId,
  participant_id: ParticipantId,
): ObserveScope =>
  Object.freeze({ scope: 'participant', conversation_id, participant_id })

export const legScope = (
  conversation_id: ConversationId,
  participant_id: ParticipantId,
  leg_id: LegId,
): ObserveScope =>
  Object.freeze({ scope: 'leg', conversation_id, participant_id, leg_id })
```

```typescript
// src/domain/conversation-bus/entities/participant-leg-target.entity.ts
import type { ConversationId, LegId, ParticipantId } from '~/domain/conversation-bus/entities/ids.entity'

export type ParticipantLegTarget = Readonly<{
  conversation_id: ConversationId
  participant_id:  ParticipantId
  leg_id:          LegId
}>
```

- [ ] **Step 4: Run tests** — PASS.
- [ ] **Step 5: Commit**

```
git add src/domain/conversation-bus/entities/observe-scope.entity.ts \
        src/domain/conversation-bus/entities/participant-leg-target.entity.ts \
        test/domain/conversation-bus/observe-scope.entity.spec.ts
git commit -m "feat(CPL-000): add ObserveScope and ParticipantLegTarget"
```

### Task 1.4: `ConversationBusPort`

**Files:**
- Create: `src/domain/conversation-bus/ports/conversation-bus.port.ts`
- Create: `src/domain/conversation-bus/index.ts`
- Create: `src/domain/conversation-bus/conversation-bus.domain.module.ts`

- [ ] **Step 1: (no test — pure type)** Implement

```typescript
// src/domain/conversation-bus/ports/conversation-bus.port.ts
import type { Observable } from 'rxjs'
import type { Result, Task, Unit } from 'true-myth'
import type { NonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import type { ObserveScope } from '~/domain/conversation-bus/entities/observe-scope.entity'
import type { ParticipantLegTarget } from '~/domain/conversation-bus/entities/participant-leg-target.entity'
import type { ConversationId } from '~/domain/conversation-bus/entities/ids.entity'
import type { ConversationBusError } from '~/domain/conversation-bus/errors/conversation-bus.error'

export const CONVERSATION_BUS = Symbol.for('ConversationBusPort')

export type ConversationStartedHandler =
  (event: NonPublicEvent) => Task<Unit, Error>

export interface ConversationBusPort {
  publishParticipantInput(
    target: ParticipantLegTarget,
    event:  NonPublicEvent,
  ): Task<Unit, ConversationBusError>

  publishParticipantOutput(
    target: ParticipantLegTarget,
    event:  NonPublicEvent,
  ): Task<Unit, ConversationBusError>

  publishConversationControl(
    conversation_id: ConversationId,
    event:           NonPublicEvent,
  ): Task<Unit, ConversationBusError>

  observeConversation(
    scope: ObserveScope,
  ): Observable<Result<NonPublicEvent, ConversationBusError>>

  observeConversationControl(
    conversation_id: ConversationId,
  ): Observable<Result<NonPublicEvent, ConversationBusError>>

  subscribeToConversationStarted(
    handler: ConversationStartedHandler,
  ): Task<Unit, ConversationBusError>

  requestConversationTermination(
    conversation_id: ConversationId,
    reason:          string,
    metadata:        Readonly<Record<string, unknown>>,
  ): Task<Unit, ConversationBusError>
}
```

```typescript
// src/domain/conversation-bus/index.ts
export * from './entities/ids.entity'
export * from './entities/non-public-event.entity'
export * from './entities/observe-scope.entity'
export * from './entities/participant-leg-target.entity'
export * from './errors/conversation-bus.error'
export * from './ports/conversation-bus.port'
```

```typescript
// src/domain/conversation-bus/conversation-bus.domain.module.ts
import { Module } from '@nestjs/common'
@Module({})
export class ConversationBusDomainModule {}
```

- [ ] **Step 2: Commit**

```
git add src/domain/conversation-bus/ports/ \
        src/domain/conversation-bus/index.ts \
        src/domain/conversation-bus/conversation-bus.domain.module.ts
git commit -m "feat(CPL-000): define ConversationBusPort and domain barrel"
```

### Task 1.5: Webhook domain (entities + errors + ports)

**Files:**
- Create: `src/domain/webhook/entities/webhook-registration.entity.ts`
- Create: `src/domain/webhook/entities/dispatch-result.entity.ts`
- Create: `src/domain/webhook/errors/webhook.error.ts`
- Create: `src/domain/webhook/ports/webhook-registration-repository.port.ts`
- Create: `src/domain/webhook/ports/webhook-dispatcher.port.ts`
- Create: `src/domain/webhook/index.ts`
- Create: `src/domain/webhook/webhook.domain.module.ts`
- Test: `test/domain/webhook/webhook-registration.entity.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/domain/webhook/webhook-registration.entity.spec.ts
import { createWebhookRegistration } from '~/domain/webhook/entities/webhook-registration.entity'
import { makeTenantId } from '~/domain/conversation-bus/entities/ids.entity'

describe('createWebhookRegistration', () => {
  it('requires at least one event_type', () => {
    const r = createWebhookRegistration({
      webhook_id: 'wh_1' as never,
      tenant_id: makeTenantId('t1').unwrapOr('' as never),
      endpoint_url: 'https://svc.internal/hooks',
      event_types: [],
      created_at: new Date(0),
    })
    expect(r.isErr).toBe(true)
  })

  it('rejects non-conversation.started event_types in v1', () => {
    const r = createWebhookRegistration({
      webhook_id: 'wh_1' as never,
      tenant_id: makeTenantId('t1').unwrapOr('' as never),
      endpoint_url: 'https://svc.internal/hooks',
      event_types: ['message.user'],
      created_at: new Date(0),
    })
    expect(r.isErr).toBe(true)
  })

  it('freezes on success', () => {
    const r = createWebhookRegistration({
      webhook_id: 'wh_1' as never,
      tenant_id: makeTenantId('t1').unwrapOr('' as never),
      endpoint_url: 'https://svc.internal/hooks',
      event_types: ['conversation.started'],
      created_at: new Date(0),
    })
    expect(r.isOk).toBe(true)
    expect(Object.isFrozen(r.unwrapOr(null as never))).toBe(true)
  })
})
```

- [ ] **Step 2: Run test** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/domain/webhook/entities/webhook-registration.entity.ts
import { Result } from 'true-myth'
import type { TenantId } from '~/domain/conversation-bus/entities/ids.entity'

type Brand<K, T> = string & { readonly __brand: K }
export type WebhookId = Brand<'WebhookId', string>

const WEBHOOK_ID_REGEX = /^wh_[A-Za-z0-9-]{1,80}$/

export class InvalidWebhookIdError extends Error {
  constructor(public readonly raw: string) {
    super(`Invalid webhook_id: ${raw}`); this.name = 'InvalidWebhookIdError'
  }
}

export const makeWebhookId = (v: string): Result<WebhookId, InvalidWebhookIdError> =>
  WEBHOOK_ID_REGEX.test(v) ? Result.ok(v as WebhookId) : Result.err(new InvalidWebhookIdError(v))

export const SUPPORTED_EVENT_TYPES = ['conversation.started'] as const
export type SupportedEventType = (typeof SUPPORTED_EVENT_TYPES)[number]

export type WebhookRegistration = Readonly<{
  webhook_id:       WebhookId
  tenant_id:        TenantId
  endpoint_url:     string
  event_types:      ReadonlyArray<SupportedEventType>
  signing_secret?:  string          // present when registration supplied one; never logged.
  created_at:       Date
}>

export type WebhookRegistrationParams = Readonly<{
  webhook_id:       WebhookId
  tenant_id:        TenantId
  endpoint_url:     string
  event_types:      ReadonlyArray<string>
  signing_secret?:  string
  created_at:       Date
}>

export class InvalidEventTypesError extends Error {
  constructor(public readonly provided: ReadonlyArray<string>) {
    super(`event_types must contain at least one of [${SUPPORTED_EVENT_TYPES.join(',')}]`)
    this.name = 'InvalidEventTypesError'
  }
}

export const createWebhookRegistration = (
  p: WebhookRegistrationParams,
): Result<WebhookRegistration, InvalidEventTypesError> => {
  const invalid = p.event_types.length === 0
    || p.event_types.some(t => !SUPPORTED_EVENT_TYPES.includes(t as SupportedEventType))
  if (invalid) return Result.err(new InvalidEventTypesError(p.event_types))
  return Result.ok(
    Object.freeze({
      ...p,
      event_types: Object.freeze(p.event_types as ReadonlyArray<SupportedEventType>),
    }),
  )
}
```

```typescript
// src/domain/webhook/entities/dispatch-result.entity.ts
export type DispatchResult =
  | { readonly outcome: 'dispatched' }
  | { readonly outcome: 'skipped_already_dispatched' }
  | { readonly outcome: 'failed_after_retries'
      readonly last_status_code?: number
      readonly attempts: number
      readonly last_error_message?: string }
```

```typescript
// src/domain/webhook/errors/webhook.error.ts
export class WebhookNotFoundError extends Error {
  constructor(public readonly webhookId: string) {
    super(`Webhook not found: ${webhookId}`); this.name = 'WebhookNotFoundError'
  }
}
export class DuplicateWebhookError extends Error {
  constructor(public readonly webhookId: string) {
    super(`Duplicate webhook: ${webhookId}`); this.name = 'DuplicateWebhookError'
  }
}
export class WebhookRepositoryError extends Error {
  constructor(public readonly cause: unknown) {
    super(cause instanceof Error ? cause.message : String(cause))
    this.name = 'WebhookRepositoryError'
  }
}
export class WebhookDispatchInfraError extends Error {
  constructor(public readonly cause: unknown) {
    super(cause instanceof Error ? cause.message : String(cause))
    this.name = 'WebhookDispatchInfraError'
  }
}
export type WebhookRegistrationError =
  | WebhookNotFoundError | DuplicateWebhookError | WebhookRepositoryError
```

```typescript
// src/domain/webhook/ports/webhook-registration-repository.port.ts
import type { Task, Unit } from 'true-myth'
import type { TenantId } from '~/domain/conversation-bus/entities/ids.entity'
import type { WebhookId, WebhookRegistration } from '~/domain/webhook/entities/webhook-registration.entity'
import type { WebhookRegistrationError } from '~/domain/webhook/errors/webhook.error'

export const WEBHOOK_REGISTRATION_REPOSITORY = Symbol.for('WebhookRegistrationRepository')

export interface WebhookRegistrationRepository {
  create(reg: WebhookRegistration): Task<Unit, WebhookRegistrationError>
  list(tenant_id: TenantId): Task<ReadonlyArray<WebhookRegistration>, WebhookRegistrationError>
  delete(webhook_id: WebhookId): Task<boolean, WebhookRegistrationError>
  findForEvent(
    event_type: string,
    tenant_id:  TenantId,
  ): Task<ReadonlyArray<WebhookRegistration>, WebhookRegistrationError>
}
```

```typescript
// src/domain/webhook/ports/webhook-dispatcher.port.ts
import type { Task } from 'true-myth'
import type { NonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import type { WebhookRegistration } from '~/domain/webhook/entities/webhook-registration.entity'
import type { DispatchResult } from '~/domain/webhook/entities/dispatch-result.entity'
import type { WebhookDispatchInfraError } from '~/domain/webhook/errors/webhook.error'

export const WEBHOOK_DISPATCHER = Symbol.for('WebhookDispatcherPort')

export interface WebhookDispatcherPort {
  dispatch(
    registration: WebhookRegistration,
    event:        NonPublicEvent,
  ): Task<DispatchResult, WebhookDispatchInfraError>
}
```

```typescript
// src/domain/webhook/index.ts
export * from './entities/webhook-registration.entity'
export * from './entities/dispatch-result.entity'
export * from './errors/webhook.error'
export * from './ports/webhook-registration-repository.port'
export * from './ports/webhook-dispatcher.port'
```

```typescript
// src/domain/webhook/webhook.domain.module.ts
import { Module } from '@nestjs/common'
@Module({})
export class WebhookDomainModule {}
```

- [ ] **Step 4: Run tests** — PASS.
- [ ] **Step 5: Commit**

```
git add src/domain/webhook test/domain/webhook
git commit -m "feat(CPL-000): add webhook domain types, errors and ports"
```

---

## Phase 2 — Subject templates, event-type map, translation service

### Task 2.1: Subject templates (lives in outbound, not service — NATS is an infra concern)

**Files:**
- Create: `src/outbound/conversation-bus/nats/subject-templates.ts`
- Test: `test/outbound/conversation-bus/nats/subject-templates.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/service/conversation-bus/subject-templates.spec.ts
import {
  channelInSubject,
  channelOutSubject,
  conversationControlSubject,
  observeFilterSubject,
  CP_CONTROL_SUBJECTS,
  CP_CONTROL_STREAMS,
  CP_CONTROL_DURABLE,
} from '~/outbound/conversation-bus/nats/subject-templates'
import { makeConversationId, makeParticipantId, makeLegId } from '~/domain/conversation-bus/entities/ids.entity'
import { conversationScope, participantScope, legScope } from '~/domain/conversation-bus/entities/observe-scope.entity'

const cid = () => makeConversationId('c1').unwrapOr('' as never)
const pid = () => makeParticipantId('p1').unwrapOr('' as never)
const lid = () => makeLegId('l1').unwrapOr('' as never)

describe('subject-templates', () => {
  it('channelIn', () => {
    expect(channelInSubject(cid(), pid())).toBe('conversation.c1.p1.channel.in')
  })
  it('channelOut', () => {
    expect(channelOutSubject(cid(), pid())).toBe('conversation.c1.p1.channel.out')
  })
  it('conversationControl', () => {
    expect(conversationControlSubject(cid())).toBe('conversation.c1.control')
  })
  it('observe conversation scope', () => {
    expect(observeFilterSubject(conversationScope(cid()))).toBe('conversation.c1.>')
  })
  it('observe participant scope', () => {
    expect(observeFilterSubject(participantScope(cid(), pid()))).toBe('conversation.c1.p1.>')
  })
  it('observe leg scope falls back to participant today', () => {
    // until subject topology splits participant and leg, leg scope == participant scope
    expect(observeFilterSubject(legScope(cid(), pid(), lid()))).toBe('conversation.c1.p1.>')
  })
  it('cp-control constants', () => {
    expect(CP_CONTROL_SUBJECTS).toEqual(['cp.control', 'cp.control.external'])
    expect(CP_CONTROL_STREAMS).toEqual(['cp-control', 'cp-control-external'])
    expect(CP_CONTROL_DURABLE).toBe('conversation-gateway-webhook-dispatcher')
  })
})
```

- [ ] **Step 2: Run test** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/outbound/conversation-bus/nats/subject-templates.ts
import type { ConversationId, LegId, ParticipantId } from '~/domain/conversation-bus/entities/ids.entity'
import type { ObserveScope } from '~/domain/conversation-bus/entities/observe-scope.entity'

export const channelInSubject  = (c: ConversationId, p: ParticipantId) => `conversation.${c}.${p}.channel.in`
export const channelOutSubject = (c: ConversationId, p: ParticipantId) => `conversation.${c}.${p}.channel.out`
export const conversationControlSubject = (c: ConversationId) => `conversation.${c}.control`

export const observeFilterSubject = (scope: ObserveScope): string => {
  switch (scope.scope) {
    case 'conversation': return `conversation.${scope.conversation_id}.>`
    case 'participant':  return `conversation.${scope.conversation_id}.${scope.participant_id}.>`
    case 'leg':          return `conversation.${scope.conversation_id}.${scope.participant_id}.>` // leg slot not split today
  }
}

export const CP_CONTROL_SUBJECTS = ['cp.control', 'cp.control.external'] as const
export const CP_CONTROL_STREAMS  = ['cp-control', 'cp-control-external'] as const
export const CP_CONTROL_DURABLE  = 'conversation-gateway-webhook-dispatcher'

export const TERMINATION_SUBJECT = 'cp.control'
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/outbound/conversation-bus/nats/subject-templates.ts \
        test/outbound/conversation-bus/nats/subject-templates.spec.ts
git commit -m "feat(CPL-000): add NATS subject templates for conversation-bus"
```

### Task 2.2: Event-type map + verb allowlists

**Files:**
- Create: `src/service/conversation-bus/event-type-map.ts`
- Test: `test/service/conversation-bus/event-type-map.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/service/conversation-bus/event-type-map.spec.ts
import {
  INTERNAL_TO_NONPUBLIC,
  NONPUBLIC_TO_INTERNAL,
  CRITICAL_EVENT_TYPES,
  isAllowedOnVerb,
} from '~/service/conversation-bus/event-type-map'

describe('event-type-map', () => {
  it('maps AgentMessage internal to message.agent non-public', () => {
    expect(INTERNAL_TO_NONPUBLIC['AgentMessage']).toBe('message.agent')
  })
  it('maps ConversationStarted internal to conversation.started', () => {
    expect(INTERNAL_TO_NONPUBLIC['ConversationStarted']).toBe('conversation.started')
  })
  it('reverse-maps message.user to UserMessage with V1 allowlist', () => {
    expect(NONPUBLIC_TO_INTERNAL['message.user'].internal_name).toBe('UserMessage')
    expect(NONPUBLIC_TO_INTERNAL['message.user'].allowedVerbs).toContain('input-events')
  })
  it('critical set contains message.user and message.agent', () => {
    expect(CRITICAL_EVENT_TYPES).toEqual(new Set(['message.user', 'message.agent']))
  })
  it('isAllowedOnVerb rejects message.agent on input-events', () => {
    expect(isAllowedOnVerb('message.agent', 'input-events')).toBe(false)
    expect(isAllowedOnVerb('message.agent', 'output-events')).toBe(true)
  })
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/service/conversation-bus/event-type-map.ts
export type Verb = 'input-events' | 'output-events' | 'control-events'

export type NonPublicToInternal = Readonly<{
  internal_name: string
  allowedVerbs:  ReadonlyArray<Verb>
}>

export const INTERNAL_TO_NONPUBLIC: Readonly<Record<string, string>> = Object.freeze({
  AgentMessage:                      'message.agent',
  UninterruptibleAgentMessage:       'message.agent',
  SensitiveDataCollectionMessage:    'message.agent',
  UserMessage:                       'message.user',
  IntermediateAgentMessageFrame:     'message.agent.intermediate',
  IntermediateUserMessageFrame:      'message.user.intermediate',
  ConversationStarted:               'conversation.started',
  ConversationEnded:                 'conversation.ended',
  ConversationTerminationRequested:  'conversation.termination-requested',
  ParticipantJoined:                 'participant.joined',
  ParticipantLeft:                   'participant.left',
  ParticipantLegAdded:               'participant.leg-added',
  ParticipantLegRemoved:             'participant.leg-removed',
  AddParticipantLegFailed:           'participant.add-leg-failed',
  PingFrame:                         'ping.frame',
  PongFrame:                         'pong.frame',
  FatalError:                        'error',
  TransientError:                    'error',
})

export const NONPUBLIC_TO_INTERNAL: Readonly<Record<string, NonPublicToInternal>> = Object.freeze({
  'message.user':                       { internal_name: 'UserMessage',                       allowedVerbs: ['input-events'] },
  'ping.frame':                         { internal_name: 'PingFrame',                         allowedVerbs: ['input-events'] },
  'message.agent':                      { internal_name: 'AgentMessage',                      allowedVerbs: ['output-events'] },
  'pong.frame':                         { internal_name: 'PongFrame',                         allowedVerbs: ['output-events'] },
  'conversation.termination-requested': { internal_name: 'ConversationTerminationRequested',  allowedVerbs: ['control-events'] },
  'participant.add-leg-requested':      { internal_name: 'AddParticipantLegRequested',        allowedVerbs: ['control-events'] },
})

export const CRITICAL_EVENT_TYPES: ReadonlySet<string> =
  new Set(['message.user', 'message.agent'])

export const isAllowedOnVerb = (eventType: string, verb: Verb): boolean =>
  NONPUBLIC_TO_INTERNAL[eventType]?.allowedVerbs.includes(verb) ?? false

// Explicit field allowlist per internal event name. Translation copies ONLY these
// fields into non-public `data`. Anything else (including future additions, NATS
// subjects, stream names) is dropped by construction. Tested by a leak fixture.
// If an internal event has no entry here, translation returns Maybe.nothing (drop).
export const ALLOWED_PAYLOAD_FIELDS: Readonly<Record<string, ReadonlyArray<string>>> = Object.freeze({
  AgentMessage:                    ['text', 'leg_id', 'direction'],
  UninterruptibleAgentMessage:     ['text', 'leg_id', 'direction'],
  SensitiveDataCollectionMessage:  ['text', 'leg_id', 'direction'],
  UserMessage:                     ['text', 'leg_id', 'direction'],
  IntermediateAgentMessageFrame:   ['text', 'leg_id', 'direction'],
  IntermediateUserMessageFrame:    ['text', 'leg_id', 'direction'],
  ConversationStarted:             ['channel_config_id', 'leg_id', 'direction', 'observability_context'],
  ConversationEnded:               ['reason', 'leg_id', 'direction'],
  ConversationTerminationRequested:['reason', 'leg_id', 'direction'],
  ParticipantJoined:               ['participant_id', 'leg_id'],
  ParticipantLeft:                 ['participant_id', 'leg_id', 'reason', 'direction'],
  ParticipantLegAdded:             ['participant_id', 'leg_id', 'leg_type', 'channel_config_id'],
  ParticipantLegRemoved:           ['participant_id', 'leg_id', 'reason', 'leg_type'],
  AddParticipantLegFailed:         ['participant_id', 'channel_config_id', 'reason'],
  PingFrame:                       ['leg_id', 'direction'],
  PongFrame:                       ['leg_id', 'direction'],
  FatalError:                      ['code', 'severity', 'message'],
  TransientError:                  ['code', 'severity', 'message'],
})
```

> **Invariant test**: every key in `INTERNAL_TO_NONPUBLIC` must also have a key in `ALLOWED_PAYLOAD_FIELDS`. Add the test below to enforce it:
>
> ```typescript
> // test/service/conversation-bus/event-type-map.spec.ts (append)
> it('every mapped internal name has an allowlist entry', () => {
>   for (const name of Object.keys(INTERNAL_TO_NONPUBLIC)) {
>     expect(ALLOWED_PAYLOAD_FIELDS[name]).toBeDefined()
>   }
> })
> ```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/service/conversation-bus/event-type-map.ts \
        test/service/conversation-bus/event-type-map.spec.ts
git commit -m "feat(CPL-000): add event-type map with verb allowlist, critical set, and per-event payload allowlist"
```

### Task 2.3: `EventTranslationService` — outbound (internal → non-public) + leak-stripping

**Files:**
- Create: `src/service/conversation-bus/event-translation.service.ts`
- Test: `test/service/conversation-bus/event-translation.service.spec.ts`
- Test fixture: `test/service/conversation-bus/fixtures/leak-fixture.json`

- [ ] **Step 1: Write fixture with every known NATS-leak field**

```json
// test/service/conversation-bus/fixtures/leak-fixture.json
{
  "name": "ConversationStarted",
  "version": "1",
  "id": "e1",
  "tenant_id": "t1",
  "conversation_id": "c1",
  "participant_id": "p1",
  "timestamp": 1,
  "payload": {
    "conversation_stream": "cp-conversations",
    "channel_input_subject": "conversation.c1.p1.channel.in",
    "channel_output_subject": "conversation.c1.p1.channel.out",
    "control_subject": "conversation.c1.control",
    "channel_config_id": "cc1",
    "leg_id": "l1",
    "direction": "inbound",
    "observability_context": { "conversation_trace_headers": { "traceparent": "00-" } }
  }
}
```

- [ ] **Step 2: Write failing test**

```typescript
// test/service/conversation-bus/event-translation.service.spec.ts
import fixture from './fixtures/leak-fixture.json'
import { EventTranslationService } from '~/service/conversation-bus/event-translation.service'

describe('EventTranslationService.toNonPublic', () => {
  const svc = new EventTranslationService()

  it('translates ConversationStarted and strips all NATS-internal fields', () => {
    const result = svc.toNonPublic(fixture as never)
    expect(result.isJust).toBe(true)
    const ev = result.unwrapOr(null as never)
    expect(ev.event_type).toBe('conversation.started')
    expect(ev.data).not.toHaveProperty('conversation_stream')
    expect(ev.data).not.toHaveProperty('channel_input_subject')
    expect(ev.data).not.toHaveProperty('channel_output_subject')
    expect(ev.data).not.toHaveProperty('control_subject')
    expect(ev.data).toHaveProperty('channel_config_id', 'cc1')
    expect(ev.data).toHaveProperty('leg_id', 'l1')
  })

  it('returns Maybe.nothing for unmapped internal name', () => {
    const raw = { ...fixture, name: 'UnknownThing' }
    expect(svc.toNonPublic(raw as never).isNothing).toBe(true)
  })
})
```

- [ ] **Step 3: Run** — FAIL.

- [ ] **Step 4: Implement**

```typescript
// src/service/conversation-bus/event-translation.service.ts
import { Injectable } from '@nestjs/common'
import { Maybe, Result } from 'true-myth'
import type { NonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import { createNonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import {
  INTERNAL_TO_NONPUBLIC,
  NONPUBLIC_TO_INTERNAL,
  ALLOWED_PAYLOAD_FIELDS,
} from '~/service/conversation-bus/event-type-map'
import {
  makeConversationId, makeEventId, makeLegId, makeParticipantId, makeTenantId,
} from '~/domain/conversation-bus/entities/ids.entity'
import { TranslationError, UnknownEventTypeError } from '~/domain/conversation-bus/errors/conversation-bus.error'

type InternalEnvelope = Readonly<{
  name: string
  version?: string
  id?: string
  tenant_id?: string
  conversation_id?: string
  participant_id?: string
  correlation_id?: string
  timestamp?: number
  payload: Readonly<Record<string, unknown>>
}>

@Injectable()
export class EventTranslationService {
  toNonPublic(internal: InternalEnvelope): Maybe<NonPublicEvent> {
    const event_type = INTERNAL_TO_NONPUBLIC[internal.name]
    if (!event_type) return Maybe.nothing()

    // Explicit allowlist: copy ONLY fields declared in ALLOWED_PAYLOAD_FIELDS for this
    // internal event. No entry → drop entirely (return Nothing below). This guarantees
    // NATS-internal fields (subjects, stream names, etc.) cannot leak by omission.
    const allowed = ALLOWED_PAYLOAD_FIELDS[internal.name]
    if (!allowed) return Maybe.nothing()
    const data: Record<string, unknown> = {}
    for (const k of allowed) {
      if (k in internal.payload) data[k] = internal.payload[k]
    }

    // Build envelope, fail soft if required fields are missing; unmapped names returned as Nothing earlier.
    const evIdR  = makeEventId(internal.id ?? '')
    const convR  = makeConversationId(internal.conversation_id ?? '')
    const tenR   = makeTenantId(internal.tenant_id ?? '')
    if (evIdR.isErr || convR.isErr || tenR.isErr) return Maybe.nothing()

    const built = createNonPublicEvent({
      event_id:        evIdR.unwrapOr('' as never),
      event_type,
      conversation_id: convR.unwrapOr('' as never),
      tenant_id:       tenR.unwrapOr('' as never),
      participant_id:  internal.participant_id
        ? makeParticipantId(internal.participant_id).map(Maybe.just).unwrapOr(Maybe.nothing())
        : Maybe.nothing(),
      leg_id:          typeof internal.payload['leg_id'] === 'string'
        ? makeLegId(internal.payload['leg_id'] as string).map(Maybe.just).unwrapOr(Maybe.nothing())
        : Maybe.nothing(),
      timestamp:       internal.timestamp ?? Date.now(),
      version:         '1',
      correlation_id:  internal.correlation_id ? Maybe.just(internal.correlation_id) : Maybe.nothing(),
      data,
    })
    return built.isOk ? Maybe.just(built.unwrapOr(null as never)) : Maybe.nothing()
  }

  toInternal(
    event: NonPublicEvent,
  ): Result<InternalEnvelope, UnknownEventTypeError | TranslationError> {
    const mapping = NONPUBLIC_TO_INTERNAL[event.event_type]
    if (!mapping) return Result.err(new UnknownEventTypeError(event.event_type))
    return Result.ok(Object.freeze({
      name:            mapping.internal_name,
      version:         '1',
      id:              event.event_id,
      tenant_id:       event.tenant_id,
      conversation_id: event.conversation_id,
      participant_id:  event.participant_id.unwrapOr(undefined as never),
      correlation_id:  event.correlation_id.unwrapOr(undefined as never),
      timestamp:       event.timestamp,
      payload:         Object.freeze({ ...event.data }),
    }))
  }

  // Builds an internal ConversationTerminationRequested envelope for gateway-originated
  // operational-recovery terminations (webhook delivery failure, SSE critical undeliverable).
  // This is the SOLE place that hand-builds internal-side envelopes; it keeps the
  // translation service as the single chokepoint for non-public ↔ internal conversion.
  buildInternalTermination(
    conversation_id: string,
    reason:          string,
    metadata:        Readonly<Record<string, unknown>>,
  ): InternalEnvelope {
    return Object.freeze({
      name:            'ConversationTerminationRequested',
      version:         '1',
      id:              `term-${conversation_id}-${Date.now()}`,
      conversation_id,
      timestamp:       Date.now(),
      payload:         Object.freeze({
        reason,
        metadata,          // NOTE: metadata is redacted by the caller (see dispatcher) before this is called
      }),
    })
  }
}
```

- [ ] **Step 5: Run** — PASS.

- [ ] **Step 6: Add a second fixture for ParticipantLegAdded and assert `subjects` stripped; repeat test.**

```json
// test/service/conversation-bus/fixtures/leg-added-fixture.json
{
  "name": "ParticipantLegAdded",
  "version": "1",
  "id": "e2",
  "tenant_id": "t1",
  "conversation_id": "c1",
  "participant_id": "p1",
  "timestamp": 1,
  "payload": {
    "participant_id": "p1",
    "leg_id": "l1",
    "leg_type": "voip",
    "channel_config_id": "cc1",
    "subjects": {
      "channel_input": "conversation.c1.p1.channel.in",
      "channel_output": "conversation.c1.p1.channel.out"
    }
  }
}
```

```typescript
// append to event-translation.service.spec.ts
import legAdded from './fixtures/leg-added-fixture.json'
it('translates ParticipantLegAdded stripping subjects', () => {
  const ev = svc.toNonPublic(legAdded as never).unwrapOr(null as never)
  expect(ev.event_type).toBe('participant.leg-added')
  expect(ev.data).not.toHaveProperty('subjects')
  expect(ev.data).toHaveProperty('leg_type', 'voip')
  expect(ev.data).toHaveProperty('channel_config_id', 'cc1')
})
```

- [ ] **Step 7: Run** — PASS.
- [ ] **Step 8: Commit**

```
git add src/service/conversation-bus/event-translation.service.ts \
        test/service/conversation-bus/event-translation.service.spec.ts \
        test/service/conversation-bus/fixtures/
git commit -m "feat(CPL-000): add EventTranslationService with NATS-leak stripping"
```

---

## Phase 2.5 — Library audit & pattern alignment (F2)

Before writing the NATS adapter, pin the actual shapes exported by the installed `@parloa/lib-message-bus` v0.15 and `@parloa/ts-redis` so tasks in Phase 3–5 match reality. The reference adapter in this repo is `src/outbound/watchdog/message-bus/resurrection-publisher.adapter.ts`.

### Task 2.5.1: Library signature snapshot

**Files:**
- Create: `docs/superpowers/plans/library-signatures.md` (audit notes, not shipped)

- [ ] **Step 1:** Open `node_modules/@parloa/lib-message-bus/dist/index.d.ts` and record for each public symbol the exact type: `MessageBus`, `NatsAdapter`, `MESSAGE_BUS` token, `MessageBusModule`, `Message`, `SubscriptionMessage`, and every method on `MessageBus` (`init`, `emit`, `attach`, `detach`, `subscribe`, `listMessages`). Confirm whether `emit` returns `Task<Unit, MessageBusError>` or `Promise<Result<Unit, MessageBusError>>`.

- [ ] **Step 2:** Open `node_modules/@parloa/ts-redis/dist/index.d.ts`. Confirm `REDIS_CLIENT` token + `Redis` type re-export (or ioredis instance type). Confirm whether `makeRedisModuleMetadata()` registers `REDIS_CLIENT` globally.

- [ ] **Step 3:** Cross-check against `src/outbound/watchdog/message-bus/resurrection-publisher.adapter.ts` and `src/outbound/watchdog/redis/watchdog.redis.adapter.ts` — these are known-working reference patterns.

- [ ] **Step 4:** If this plan's Phase 3 snippets diverge from the audited shapes, **fix the plan now** (edit Tasks 3.1, 3.2, 5.1 to match) before writing any Phase 3 code. Do not proceed with divergent types.

- [ ] **Step 5:** Commit the audit notes.

```
git add docs/superpowers/plans/library-signatures.md
git commit -m "docs(CPL-000): snapshot @parloa/lib-message-bus and @parloa/ts-redis signatures for Phase 3 alignment"
```

---

## Phase 3 — NATS outbound adapter

### Task 3.1: Adapter skeleton + `publishParticipantInput`

**Files:**
- Create: `src/outbound/conversation-bus/nats/conversation-bus-nats.adapter.ts`
- Create: `src/outbound/conversation-bus/nats/conversation-bus.outbound.module.ts`
- Test: `test/outbound/conversation-bus/nats/conversation-bus-nats.adapter.integration-spec.ts`

- [ ] **Step 1: Failing integration test (testcontainers-nats)**

```typescript
// test/outbound/conversation-bus/nats/conversation-bus-nats.adapter.integration-spec.ts
import { NatsContainer, StartedNatsContainer } from '@testcontainers/nats'
import { connect, NatsConnection } from 'nats'
import { NatsAdapter, MessageBus } from '@parloa/lib-message-bus'
import { Result } from 'true-myth'
import { ConversationBusNatsAdapter } from '~/outbound/conversation-bus/nats/conversation-bus-nats.adapter'
import { EventTranslationService } from '~/service/conversation-bus/event-translation.service'
import { makeConversationId, makeParticipantId, makeLegId, makeTenantId, makeEventId } from '~/domain/conversation-bus/entities/ids.entity'
import { createNonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import { Maybe } from 'true-myth'

let container: StartedNatsContainer
let nc: NatsConnection
let bus: MessageBus
let adapter: ConversationBusNatsAdapter

beforeAll(async () => {
  container = await new NatsContainer('nats:2.10').withJetStream().start()
  nc = await connect({ servers: container.getConnectionUrl() })
  bus = NatsAdapter(nc)
  adapter = new ConversationBusNatsAdapter(bus, new EventTranslationService())
}, 60_000)

afterAll(async () => {
  await nc.drain()
  await container.stop()
})

it('publishParticipantInput emits to conversation.{cid}.{pid}.channel.in', async () => {
  const subjectReceived: string[] = []
  const sub = nc.subscribe('conversation.c1.p1.channel.in', {
    callback: (_, msg) => subjectReceived.push(msg.subject),
  })

  const event = createNonPublicEvent({
    event_id:        makeEventId('e1').unwrapOr('' as never),
    event_type:      'message.user',
    conversation_id: makeConversationId('c1').unwrapOr('' as never),
    tenant_id:       makeTenantId('t1').unwrapOr('' as never),
    participant_id:  Maybe.just(makeParticipantId('p1').unwrapOr('' as never)),
    leg_id:          Maybe.just(makeLegId('l1').unwrapOr('' as never)),
    timestamp: Date.now(), version: '1',
    correlation_id: Maybe.nothing(),
    data: { text: 'hello' },
  }).unwrapOr(null as never)

  const task = adapter.publishParticipantInput(
    { conversation_id: event.conversation_id, participant_id: event.participant_id.unwrapOr('' as never), leg_id: event.leg_id.unwrapOr('' as never) },
    event,
  )
  const result = await task.toPromise()
  expect(result).toEqual(Result.ok(undefined))

  await new Promise(r => setTimeout(r, 100))
  sub.unsubscribe()
  expect(subjectReceived).toEqual(['conversation.c1.p1.channel.in'])
}, 30_000)
```

- [ ] **Step 2: Run** — FAIL (module not found).

- [ ] **Step 3: Implement adapter skeleton + method**

```typescript
// src/outbound/conversation-bus/nats/conversation-bus-nats.adapter.ts
import { Inject, Injectable } from '@nestjs/common'
import type { Observable } from 'rxjs'
import { map as rxMap } from 'rxjs/operators'
import { Result, Task, Unit } from 'true-myth'
import { fromPromise } from 'true-myth/task'
import { MESSAGE_BUS, MessageBus } from '@parloa/lib-message-bus'
import type {
  ConversationBusPort,
  ConversationStartedHandler,
} from '~/domain/conversation-bus/ports/conversation-bus.port'
import type { ParticipantLegTarget } from '~/domain/conversation-bus/entities/participant-leg-target.entity'
import type { NonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import type { ObserveScope } from '~/domain/conversation-bus/entities/observe-scope.entity'
import type { ConversationId } from '~/domain/conversation-bus/entities/ids.entity'
import {
  ConversationBusObserveError,
  ConversationBusPublishError,
  type ConversationBusError,
} from '~/domain/conversation-bus/errors/conversation-bus.error'
import {
  channelInSubject,
  channelOutSubject,
  conversationControlSubject,
  observeFilterSubject,
  CP_CONTROL_STREAMS,
  CP_CONTROL_SUBJECTS,
  CP_CONTROL_DURABLE,
  TERMINATION_SUBJECT,
} from '~/outbound/conversation-bus/nats/subject-templates'
import { EventTranslationService } from '~/service/conversation-bus/event-translation.service'

@Injectable()
export class ConversationBusNatsAdapter implements ConversationBusPort {
  constructor(
    @Inject(MESSAGE_BUS) private readonly bus: MessageBus,
    private readonly translation: EventTranslationService,
  ) {}

  publishParticipantInput(target: ParticipantLegTarget, event: NonPublicEvent) {
    return this.emit(channelInSubject(target.conversation_id, target.participant_id), event)
  }

  publishParticipantOutput(target: ParticipantLegTarget, event: NonPublicEvent) {
    return this.emit(channelOutSubject(target.conversation_id, target.participant_id), event)
  }

  publishConversationControl(conversation_id: ConversationId, event: NonPublicEvent) {
    return this.emit(conversationControlSubject(conversation_id), event)
  }

  private emit(subject: string, event: NonPublicEvent): Task<Unit, ConversationBusError> {
    return this.translation
      .toInternal(event)
      .match({
        Ok: internal => this.bus
          .emit(subject, Buffer.from(JSON.stringify(internal)), { 'Nats-Msg-Id': event.event_id })
          .map(() => Unit)
          .mapRejected(e => new ConversationBusPublishError(e) as ConversationBusError),
        Err: (e: ConversationBusError) => Task.reject<Unit, ConversationBusError>(e),
      })
  }

  observeConversation(scope: ObserveScope): Observable<Result<NonPublicEvent, ConversationBusError>> {
    return this.subscribeAndTranslate(observeFilterSubject(scope))
  }

  observeConversationControl(conversation_id: ConversationId): Observable<Result<NonPublicEvent, ConversationBusError>> {
    return this.subscribeAndTranslate(conversationControlSubject(conversation_id))
  }

  private subscribeAndTranslate(subject: string) {
    return this.bus.subscribe(subject).pipe(
      rxMap(r => r
        .mapErr(e => new ConversationBusObserveError(e) as ConversationBusError)
        .andThen(msg => {
          try {
            const internal = JSON.parse(Buffer.from(msg.data).toString())
            const maybeEv = this.translation.toNonPublic(internal)
            return maybeEv.isJust
              ? Result.ok<NonPublicEvent, ConversationBusError>(maybeEv.unwrapOr(null as never))
              : Result.err<NonPublicEvent, ConversationBusError>(new ConversationBusObserveError(new Error('untranslatable')))
          } catch (e) {
            return Result.err<NonPublicEvent, ConversationBusError>(new ConversationBusObserveError(e))
          }
        })),
    )
  }

  subscribeToConversationStarted(handler: ConversationStartedHandler): Task<Unit, ConversationBusError> {
    // Expanded in Task 3.2 — this skeleton rejects for now.
    return Task.reject(new ConversationBusObserveError(new Error('not implemented')))
  }

  requestConversationTermination(
    conversation_id: ConversationId,
    reason: string,
    metadata: Readonly<Record<string, unknown>>,
  ) {
    // Delegate envelope construction to the translation service so all non-public ↔ internal
    // shaping lives in one place. See EventTranslationService.buildInternalTermination.
    const envelope = this.translation.buildInternalTermination(conversation_id, reason, metadata)
    return this.bus
      .emit(TERMINATION_SUBJECT, Buffer.from(JSON.stringify(envelope)))
      .map(() => Unit)
      .mapRejected(e => new ConversationBusPublishError(e) as ConversationBusError)
  }
}
```

- [ ] **Step 4: Module wiring**

```typescript
// src/service/conversation-bus/conversation-bus.service.module.ts
import { Module } from '@nestjs/common'
import { EventTranslationService } from './event-translation.service'

@Module({
  providers: [EventTranslationService],
  exports:   [EventTranslationService],
})
export class ConversationBusServiceModule {}
```

```typescript
// src/outbound/conversation-bus/nats/conversation-bus.outbound.module.ts
import { Module } from '@nestjs/common'
import { CONVERSATION_BUS } from '~/domain/conversation-bus/ports/conversation-bus.port'
import { ConversationBusServiceModule } from '~/service/conversation-bus/conversation-bus.service.module'
import { ConversationBusNatsAdapter } from './conversation-bus-nats.adapter'

// MessageBusModule is registered globally in AppModule (forRootAsync). This module
// provides only the ConversationBusPort binding. Inbound modules must NOT import
// this module directly — they depend on ConversationBusPort and get the binding
// through AppModule.
@Module({
  imports: [ConversationBusServiceModule],
  providers: [
    ConversationBusNatsAdapter,
    { provide: CONVERSATION_BUS, useExisting: ConversationBusNatsAdapter },
  ],
  exports: [CONVERSATION_BUS],
})
export class ConversationBusOutboundModule {}
```

- [ ] **Step 5: Run integration test** — PASS.
- [ ] **Step 6: Commit**

```
git add src/outbound/conversation-bus test/outbound/conversation-bus
git commit -m "feat(CPL-000): add ConversationBusNatsAdapter publish paths"
```

### Task 3.2: `subscribeToConversationStarted` (durable JetStream, 2 streams)

**Files:**
- Modify: `src/outbound/conversation-bus/nats/conversation-bus-nats.adapter.ts`
- Test: extend integration spec

- [ ] **Step 1: Failing test**

```typescript
// append to conversation-bus-nats.adapter.integration-spec.ts
it('subscribeToConversationStarted delivers ConversationStarted events and ACKs', async () => {
  // Prepare streams
  const js = nc.jetstreamManager()
  await (await js).streams.add({ name: 'cp-control', subjects: ['cp.control'] })
  await (await js).streams.add({ name: 'cp-control-external', subjects: ['cp.control.external'] })

  const received: string[] = []
  await adapter
    .subscribeToConversationStarted(async ev => {
      received.push(ev.event_type)
      return Task.resolve(undefined) as never
    })
    .toPromise()

  // Publish a ConversationStarted via raw JetStream
  await nc.jetstream().publish(
    'cp.control',
    Buffer.from(JSON.stringify({
      name: 'ConversationStarted',
      id: 'e1', tenant_id: 't1', conversation_id: 'c1', timestamp: 1,
      payload: {
        channel_config_id: 'cc1',
        conversation_stream: 'cp-conversations',
        channel_input_subject: 's.in', channel_output_subject: 's.out', control_subject: 's.ctl',
        leg_id: 'l1', direction: 'inbound',
      },
    })),
  )

  await new Promise(r => setTimeout(r, 500))
  expect(received).toContain('conversation.started')
}, 30_000)
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// replace the stub in ConversationBusNatsAdapter
subscribeToConversationStarted(handler: ConversationStartedHandler): Task<Unit, ConversationBusError> {
  const attach = (stream: string) =>
    this.bus.attach(stream, CP_CONTROL_DURABLE, {
      subjects: [], // matches anything in the stream
      maxDeliver: 3,
      ackWaitSeconds: 15,
    })
  const observable$ = Task.resolve(undefined)
    .andThen(() => Task.all([attach(CP_CONTROL_STREAMS[0]), attach(CP_CONTROL_STREAMS[1])]))
    .map(([a, b]) => {
      const subscribe = (obs: any) =>
        obs.subscribe((r: Result<any, any>) =>
          r.match({
            Ok: async (msg: any) => {
              try {
                const internal = JSON.parse(Buffer.from(msg.data).toString())
                const maybeEv = this.translation.toNonPublic(internal)
                if (maybeEv.isNothing) { msg.resolve(); return }
                const res = await handler(maybeEv.unwrapOr(null as never)).toPromise()
                res.isOk ? msg.resolve() : msg.reject()
              } catch {
                msg.reject()
              }
            },
            Err: () => {},
          }),
        )
      subscribe(a); subscribe(b)
      return Unit
    })
    .mapRejected(e => new ConversationBusObserveError(e) as ConversationBusError)
  return observable$ as Task<Unit, ConversationBusError>
}
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/outbound/conversation-bus/nats/conversation-bus-nats.adapter.ts \
        test/outbound/conversation-bus/nats/conversation-bus-nats.adapter.integration-spec.ts
git commit -m "feat(CPL-000): durable JetStream consumer for conversation.started on cp-control*"
```

### Task 3.3: `observe*` integration tests + `requestConversationTermination` test

- [ ] **Step 1: Add integration tests**

```typescript
// append to conversation-bus-nats.adapter.integration-spec.ts
import { conversationScope } from '~/domain/conversation-bus/entities/observe-scope.entity'

it('observeConversation streams events on subject pattern', async () => {
  const events: string[] = []
  const subscription = adapter.observeConversation(conversationScope('c1' as never)).subscribe({
    next: r => r.match({ Ok: ev => events.push(ev.event_type), Err: () => {} }),
  })

  // Publish an internal AgentMessage via raw NATS
  nc.publish('conversation.c1.p1.channel.out', Buffer.from(JSON.stringify({
    name: 'AgentMessage', id: 'e1', tenant_id: 't1', conversation_id: 'c1', participant_id: 'p1',
    timestamp: 1, payload: { text: 'hi', leg_id: 'l1', direction: 'outbound' },
  })))
  await new Promise(r => setTimeout(r, 200))
  subscription.unsubscribe()
  expect(events).toContain('message.agent')
})

it('requestConversationTermination publishes to cp.control', async () => {
  const captured: string[] = []
  const sub = nc.subscribe('cp.control', { callback: (_, m) => captured.push(m.subject) })
  const result = await adapter
    .requestConversationTermination('c1' as never, 'webhook_delivery_failed', { webhook_id: 'wh_1' })
    .toPromise()
  expect(result.isOk).toBe(true)
  await new Promise(r => setTimeout(r, 100))
  sub.unsubscribe()
  expect(captured).toContain('cp.control')
})
```

- [ ] **Step 2: Run** — PASS (observe/termination were already implemented in Task 3.1's skeleton).
- [ ] **Step 3: Commit**

```
git add test/outbound/conversation-bus/nats/conversation-bus-nats.adapter.integration-spec.ts
git commit -m "test(CPL-000): observe and termination paths for NATS adapter"
```

---

## Phase 4 — Redis webhook registration adapter

### Task 4.1: Adapter skeleton + `create` + `findForEvent`

**Files:**
- Create: `src/outbound/webhook/redis/webhook-registration.redis.adapter.ts`
- Create: `src/outbound/webhook/redis/webhook-registration.outbound.module.ts`
- Test: `test/outbound/webhook/redis/webhook-registration.redis.adapter.integration-spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/outbound/webhook/redis/webhook-registration.redis.adapter.integration-spec.ts
import { GenericContainer, StartedTestContainer } from 'testcontainers'
import Redis from 'ioredis'
import { WebhookRegistrationRedisRepository } from '~/outbound/webhook/redis/webhook-registration.redis.adapter'
import { createWebhookRegistration } from '~/domain/webhook/entities/webhook-registration.entity'
import { makeTenantId } from '~/domain/conversation-bus/entities/ids.entity'

let container: StartedTestContainer
let redis: Redis
let repo: WebhookRegistrationRedisRepository

beforeAll(async () => {
  container = await new GenericContainer('redis:7').withExposedPorts(6379).start()
  redis = new Redis(container.getMappedPort(6379), container.getHost())
  repo = new WebhookRegistrationRedisRepository(redis as never)
}, 60_000)

afterAll(async () => { await redis.quit(); await container.stop() })

it('create + findForEvent returns the registration', async () => {
  const reg = createWebhookRegistration({
    webhook_id: 'wh_1' as never,
    tenant_id: makeTenantId('t1').unwrapOr('' as never),
    endpoint_url: 'https://svc/hook',
    event_types: ['conversation.started'],
    created_at: new Date(),
  }).unwrapOr(null as never)
  expect((await repo.create(reg).toPromise()).isOk).toBe(true)
  const found = await repo.findForEvent('conversation.started', reg.tenant_id).toPromise()
  expect(found.unwrapOr([]).map(r => r.webhook_id)).toEqual(['wh_1'])
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/outbound/webhook/redis/webhook-registration.redis.adapter.ts
import { Inject, Injectable } from '@nestjs/common'
import { REDIS_CLIENT, type Redis } from '@parloa/ts-redis'
import { fromPromise } from 'true-myth/task'
import { Task, Unit } from 'true-myth'
import type { TenantId } from '~/domain/conversation-bus/entities/ids.entity'
import type {
  WebhookRegistration,
  WebhookId,
} from '~/domain/webhook/entities/webhook-registration.entity'
import type { WebhookRegistrationRepository } from '~/domain/webhook/ports/webhook-registration-repository.port'
import {
  WebhookNotFoundError, WebhookRepositoryError,
  type WebhookRegistrationError,
} from '~/domain/webhook/errors/webhook.error'

const key = (id: WebhookId) => `cg:webhook:${id}`
const byTenant = (t: TenantId) => `cg:webhooks:by-tenant:${t}`
const byEventType = (e: string, t: TenantId) => `cg:webhooks:by-event-type:${e}:${t}`

@Injectable()
export class WebhookRegistrationRedisRepository implements WebhookRegistrationRepository {
  constructor(@Inject(REDIS_CLIENT) private readonly redis: Redis) {}

  create(reg: WebhookRegistration): Task<Unit, WebhookRegistrationError> {
    return fromPromise(
      this.redis.multi()
        .set(key(reg.webhook_id), JSON.stringify({ ...reg, created_at: reg.created_at.toISOString() }))
        .sadd(byTenant(reg.tenant_id), reg.webhook_id)
        .sadd(byEventType(reg.event_types[0], reg.tenant_id), reg.webhook_id)
        .exec()
        .then(() => undefined as void),
    ).map(() => Unit).mapRejected(e => new WebhookRepositoryError(e) as WebhookRegistrationError)
  }

  list(tenant_id: TenantId) {
    return fromPromise(
      (async () => {
        const ids = await this.redis.smembers(byTenant(tenant_id))
        if (ids.length === 0) return [] as WebhookRegistration[]
        const pipe = this.redis.pipeline()
        ids.forEach(id => pipe.get(key(id as WebhookId)))
        const rows = await pipe.exec()
        return (rows ?? [])
          .map(([_, v]) => v as string | null)
          .filter((v): v is string => !!v)
          .map(raw => {
            const parsed = JSON.parse(raw)
            return { ...parsed, created_at: new Date(parsed.created_at) } as WebhookRegistration
          })
      })(),
    ).mapRejected(e => new WebhookRepositoryError(e) as WebhookRegistrationError)
  }

  delete(webhook_id: WebhookId) {
    return fromPromise(
      (async () => {
        const raw = await this.redis.get(key(webhook_id))
        if (!raw) return false
        const reg = JSON.parse(raw) as WebhookRegistration
        await this.redis.multi()
          .del(key(webhook_id))
          .srem(byTenant(reg.tenant_id), webhook_id)
          .srem(byEventType(reg.event_types[0], reg.tenant_id), webhook_id)
          .exec()
        return true
      })(),
    ).mapRejected(e => new WebhookRepositoryError(e) as WebhookRegistrationError)
  }

  findForEvent(event_type: string, tenant_id: TenantId) {
    return fromPromise(
      (async () => {
        const ids = await this.redis.smembers(byEventType(event_type, tenant_id))
        if (ids.length === 0) return [] as WebhookRegistration[]
        const pipe = this.redis.pipeline()
        ids.forEach(id => pipe.get(key(id as WebhookId)))
        const rows = await pipe.exec()
        return (rows ?? [])
          .map(([_, v]) => v as string | null)
          .filter((v): v is string => !!v)
          .map(raw => {
            const parsed = JSON.parse(raw)
            return { ...parsed, created_at: new Date(parsed.created_at) } as WebhookRegistration
          })
      })(),
    ).mapRejected(e => new WebhookRepositoryError(e) as WebhookRegistrationError)
  }
}
```

```typescript
// src/outbound/webhook/redis/webhook-registration.outbound.module.ts
import { Module } from '@nestjs/common'
import { WEBHOOK_REGISTRATION_REPOSITORY } from '~/domain/webhook/ports/webhook-registration-repository.port'
import { WebhookRegistrationRedisRepository } from './webhook-registration.redis.adapter'

@Module({
  providers: [
    WebhookRegistrationRedisRepository,
    { provide: WEBHOOK_REGISTRATION_REPOSITORY, useExisting: WebhookRegistrationRedisRepository },
  ],
  exports: [WEBHOOK_REGISTRATION_REPOSITORY],
})
export class WebhookRegistrationOutboundModule {}
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Add `list` + `delete` tests and run — PASS.**
- [ ] **Step 6: Commit**

```
git add src/outbound/webhook/redis test/outbound/webhook/redis
git commit -m "feat(CPL-000): add WebhookRegistrationRedisRepository"
```

---

## Phase 5 — HTTP webhook dispatcher

### Task 5.1: `WebhookHttpDispatcher` — SETNX + retry + metrics

**Files:**
- Create: `src/outbound/webhook/http/webhook-http-dispatcher.adapter.ts`
- Create: `src/outbound/webhook/http/webhook-http-dispatcher.outbound.module.ts`
- Test: `test/outbound/webhook/http/webhook-http-dispatcher.adapter.integration-spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/outbound/webhook/http/webhook-http-dispatcher.adapter.integration-spec.ts
import http from 'node:http'
import Redis from 'ioredis'
import { GenericContainer, StartedTestContainer } from 'testcontainers'
import { WebhookHttpDispatcher } from '~/outbound/webhook/http/webhook-http-dispatcher.adapter'
import { createWebhookRegistration } from '~/domain/webhook/entities/webhook-registration.entity'
import { makeTenantId, makeEventId, makeConversationId } from '~/domain/conversation-bus/entities/ids.entity'
import { createNonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import { Maybe } from 'true-myth'

let container: StartedTestContainer
let redis: Redis
let dispatcher: WebhookHttpDispatcher
let srv: http.Server
let srvPort = 0
let handler: (req: http.IncomingMessage, res: http.ServerResponse) => void

beforeAll(async () => {
  container = await new GenericContainer('redis:7').withExposedPorts(6379).start()
  redis = new Redis(container.getMappedPort(6379), container.getHost())
  dispatcher = new WebhookHttpDispatcher(redis as never)
  srv = http.createServer((req, res) => handler(req, res))
  await new Promise<void>(r => srv.listen(0, () => r()))
  srvPort = (srv.address() as any).port
}, 60_000)
afterAll(async () => { srv.close(); await redis.quit(); await container.stop() })

const event = () => createNonPublicEvent({
  event_id: makeEventId('e1').unwrapOr('' as never),
  event_type: 'conversation.started',
  conversation_id: makeConversationId('c1').unwrapOr('' as never),
  tenant_id: makeTenantId('t1').unwrapOr('' as never),
  participant_id: Maybe.nothing(), leg_id: Maybe.nothing(),
  timestamp: 1, version: '1', correlation_id: Maybe.nothing(),
  data: {},
}).unwrapOr(null as never)

const reg = (url: string) => createWebhookRegistration({
  webhook_id: ('wh_' + Math.random()) as never,
  tenant_id: makeTenantId('t1').unwrapOr('' as never),
  endpoint_url: url,
  event_types: ['conversation.started'],
  created_at: new Date(),
}).unwrapOr(null as never)

it('dispatched on 2xx', async () => {
  handler = (_, res) => { res.statusCode = 200; res.end() }
  const r = await dispatcher.dispatch(reg(`http://127.0.0.1:${srvPort}/`), event()).toPromise()
  expect(r.unwrapOr(null as never).outcome).toBe('dispatched')
})

it('failed_after_retries on permanent 5xx', async () => {
  handler = (_, res) => { res.statusCode = 500; res.end() }
  const r = await dispatcher.dispatch(reg(`http://127.0.0.1:${srvPort}/`), event()).toPromise()
  const res = r.unwrapOr(null as never) as any
  expect(res.outcome).toBe('failed_after_retries')
  expect(res.attempts).toBe(3)
})

it('skipped_already_dispatched when SETNX lost', async () => {
  handler = (_, res) => { res.statusCode = 200; res.end() }
  const r1 = reg(`http://127.0.0.1:${srvPort}/`)
  await dispatcher.dispatch(r1, event()).toPromise()
  const r = await dispatcher.dispatch(r1, event()).toPromise()
  expect(r.unwrapOr(null as never).outcome).toBe('skipped_already_dispatched')
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/outbound/webhook/http/webhook-http-dispatcher.adapter.ts
import { createHash } from 'node:crypto'
import { Inject, Injectable } from '@nestjs/common'
import { ConfigService } from '@nestjs/config'
import { REDIS_CLIENT, type Redis } from '@parloa/ts-redis'
import { fromPromise } from 'true-myth/task'
import { Task } from 'true-myth'
import type { NonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import type { WebhookRegistration } from '~/domain/webhook/entities/webhook-registration.entity'
import type { DispatchResult } from '~/domain/webhook/entities/dispatch-result.entity'
import { WebhookDispatchInfraError } from '~/domain/webhook/errors/webhook.error'
import { resolveToSafeTarget } from './safe-url.validator'

// SETNX TTL must exceed NATS maxDeliver × ackWaitSeconds (currently 3 × 15s = 45s)
// so that an ACKed-but-re-delivered event still hits the lock and skips.
const LOCK_TTL = 120
const BUDGET_MS = 10_000
const ATTEMPT_TIMEOUT_MS = 2_000
const MAX_ATTEMPTS = 3
const BACKOFF_BASE_MS = 500

const delay = (ms: number) => new Promise<void>(r => setTimeout(r, ms))
const jitter = (ms: number) => ms + Math.random() * ms * 0.3

@Injectable()
export class WebhookHttpDispatcher {
  constructor(
    @Inject(REDIS_CLIENT) private readonly redis: Redis,
    private readonly config: ConfigService,
  ) {}

  dispatch(
    registration: WebhookRegistration,
    event: NonPublicEvent,
  ): Task<DispatchResult, WebhookDispatchInfraError> {
    return fromPromise(this.tryDispatch(registration, event))
      .mapRejected(e => new WebhookDispatchInfraError(e))
  }

  private get urlOpts() {
    return {
      allowedSchemes: (this.config.get<string>('WEBHOOK_ALLOWED_SCHEMES', 'https')).split(','),
      allowedHostSuffixes: (this.config.get<string>('WEBHOOK_ALLOWED_HOST_SUFFIXES', '.internal.parloa.com')).split(','),
    }
  }

  private async tryDispatch(
    registration: WebhookRegistration,
    event: NonPublicEvent,
  ): Promise<DispatchResult> {
    // SSRF guard: re-validate at dispatch time and pin the resolved IP. A URL that
    // passed registration but now resolves to a private IP (DNS rebinding) is blocked.
    const target = await resolveToSafeTarget(registration.endpoint_url, this.urlOpts)
    if (target.isErr) {
      const err = target.unwrapErr()
      return {
        outcome: 'failed_after_retries',
        attempts: 0,
        last_error_message: `ssrf_blocked:${err.code}`,
      }
    }
    const { url, pinnedIp } = target.unwrapOr(null as never)

    // Dedup key combines event_id with a content hash so a caller can't pre-poison
    // the key for a future conversation.started (key-suppression attack). If two pods
    // receive the exact same bytes with the same event_id, they compute the same hash
    // and exactly one wins SETNX. Different bytes with the same id hash differently
    // (caller-controlled id is not enough to collide).
    const bodyBytes = JSON.stringify(event)
    const contentHash = createHash('sha256').update(bodyBytes).digest('hex').slice(0, 16)
    const lockKey = `cg:webhook-dispatched:${event.event_id}:${contentHash}:${registration.webhook_id}`
    const won = await this.redis.set(lockKey, '1', 'EX', LOCK_TTL, 'NX')
    if (won !== 'OK') return { outcome: 'skipped_already_dispatched' }

    const start = Date.now()
    let lastStatus: number | undefined
    let lastErr: string | undefined
    for (let attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
      if (Date.now() - start >= BUDGET_MS) break
      try {
        const res = await this.post(url, pinnedIp, event, registration.signing_secret)
        lastStatus = res.status
        if (res.status >= 200 && res.status < 300) return { outcome: 'dispatched' }
      } catch (e) {
        lastErr = e instanceof Error ? e.message : String(e)
      }
      if (attempt < MAX_ATTEMPTS) {
        const remaining = BUDGET_MS - (Date.now() - start)
        if (remaining <= 0) break
        await delay(Math.min(remaining, jitter(BACKOFF_BASE_MS * 2 ** (attempt - 1))))
      }
    }
    return {
      outcome: 'failed_after_retries',
      last_status_code: lastStatus,
      attempts: MAX_ATTEMPTS,
      last_error_message: lastErr,
    }
  }

  private async post(
    url: URL,
    pinnedIp: string,
    body: unknown,
    signingSecret: string | undefined,
  ): Promise<{ status: number }> {
    const ctrl = new AbortController()
    const t = setTimeout(() => ctrl.abort(), ATTEMPT_TIMEOUT_MS)
    try {
      const signingEnabled = this.config.get<boolean>('WEBHOOK_SIGNING_ENABLED', false)
      const bodyStr = JSON.stringify(body)
      const headers: Record<string, string> = {
        'content-type': 'application/json',
        host: url.hostname,
      }
      if (signingEnabled && signingSecret) {
        const ts = Math.floor(Date.now() / 1000).toString()
        const sig = createHash('sha256')
          .update(`${ts}.${bodyStr}`)
          .update(signingSecret)
          .digest('hex')
        headers['x-parloa-timestamp'] = ts
        headers['x-parloa-signature'] = `sha256=${sig}`
      }
      // Dispatch to the IP we pinned at validation time and carry the hostname in the Host
      // header so TLS + virtual-host routing still work. This defeats DNS rebinding between
      // lookup and connect.
      const ipUrl = new URL(url.toString())
      ipUrl.hostname = pinnedIp
      const res = await fetch(ipUrl.toString(), {
        method: 'POST',
        headers,
        body: bodyStr,
        signal: ctrl.signal,
        redirect: 'manual',
      })
      return { status: res.status }
    } finally {
      clearTimeout(t)
    }
  }
}
```

- [ ] **Step 4: Module wiring**

```typescript
// src/outbound/webhook/http/webhook-http-dispatcher.outbound.module.ts
import { Module } from '@nestjs/common'
import { WEBHOOK_DISPATCHER } from '~/domain/webhook/ports/webhook-dispatcher.port'
import { WebhookHttpDispatcher } from './webhook-http-dispatcher.adapter'

@Module({
  providers: [
    WebhookHttpDispatcher,
    { provide: WEBHOOK_DISPATCHER, useExisting: WebhookHttpDispatcher },
  ],
  exports: [WEBHOOK_DISPATCHER],
})
export class WebhookHttpDispatcherOutboundModule {}
```

- [ ] **Step 5: Run** — PASS.
- [ ] **Step 6: Commit**

```
git add src/outbound/webhook/http test/outbound/webhook/http
git commit -m "feat(CPL-000): add WebhookHttpDispatcher with SETNX dedup and retry"
```

---

## Phase 6 — Webhook dispatch service

### Task 6.1: `WebhookDispatchService`

**Files:**
- Create: `src/service/webhook/webhook-dispatch.service.ts`
- Create: `src/service/webhook/webhook.service.module.ts`
- Test: `test/service/webhook/webhook-dispatch.service.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/service/webhook/webhook-dispatch.service.spec.ts
import { Task, Unit, Maybe } from 'true-myth'
import { WebhookDispatchService } from '~/service/webhook/webhook-dispatch.service'
import { createNonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import { makeConversationId, makeEventId, makeTenantId } from '~/domain/conversation-bus/entities/ids.entity'
import type { ConversationBusPort } from '~/domain/conversation-bus/ports/conversation-bus.port'
import type { WebhookRegistrationRepository } from '~/domain/webhook/ports/webhook-registration-repository.port'
import type { WebhookDispatcherPort } from '~/domain/webhook/ports/webhook-dispatcher.port'

const ev = () => createNonPublicEvent({
  event_id: makeEventId('e1').unwrapOr('' as never),
  event_type: 'conversation.started',
  conversation_id: makeConversationId('c1').unwrapOr('' as never),
  tenant_id: makeTenantId('t1').unwrapOr('' as never),
  participant_id: Maybe.nothing(), leg_id: Maybe.nothing(),
  timestamp: 1, version: '1', correlation_id: Maybe.nothing(),
  data: {},
}).unwrapOr(null as never)

it('fans out to all tenant registrations and returns Task.ok', async () => {
  const regs = [
    { webhook_id: 'wh_1' as never, tenant_id: 't1' as never, endpoint_url: 'u1', event_types: ['conversation.started'] as const, created_at: new Date() },
    { webhook_id: 'wh_2' as never, tenant_id: 't1' as never, endpoint_url: 'u2', event_types: ['conversation.started'] as const, created_at: new Date() },
  ]
  const dispatched: string[] = []
  const repo: WebhookRegistrationRepository = {
    create: jest.fn(), list: jest.fn(), delete: jest.fn(),
    findForEvent: () => Task.resolve(regs),
  }
  const dispatcher: WebhookDispatcherPort = {
    dispatch: (reg) => { dispatched.push(reg.webhook_id); return Task.resolve({ outcome: 'dispatched' as const }) },
  }
  const bus: Partial<ConversationBusPort> = {
    requestConversationTermination: jest.fn(() => Task.resolve(Unit) as never),
  }
  const svc = new WebhookDispatchService(bus as ConversationBusPort, repo, dispatcher)
  const r = await svc.onEvent(ev()).toPromise()
  expect(r.isOk).toBe(true)
  expect(dispatched.sort()).toEqual(['wh_1', 'wh_2'])
})

it('triggers termination on failed_after_retries', async () => {
  const regs = [
    { webhook_id: 'wh_1' as never, tenant_id: 't1' as never, endpoint_url: 'u1', event_types: ['conversation.started'] as const, created_at: new Date() },
  ]
  const repo: WebhookRegistrationRepository = {
    create: jest.fn(), list: jest.fn(), delete: jest.fn(),
    findForEvent: () => Task.resolve(regs),
  }
  const dispatcher: WebhookDispatcherPort = {
    dispatch: () => Task.resolve({ outcome: 'failed_after_retries' as const, attempts: 3 }),
  }
  const termination = jest.fn(() => Task.resolve(Unit) as never)
  const bus: Partial<ConversationBusPort> = { requestConversationTermination: termination }
  const svc = new WebhookDispatchService(bus as ConversationBusPort, repo, dispatcher)
  await svc.onEvent(ev()).toPromise()
  expect(termination).toHaveBeenCalledWith('c1', 'webhook_delivery_failed', expect.any(Object))
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/service/webhook/webhook-dispatch.service.ts
import { Inject, Injectable, OnModuleInit } from '@nestjs/common'
import { Task, Unit } from 'true-myth'
import { fromPromise } from 'true-myth/task'
import { CONVERSATION_BUS, type ConversationBusPort } from '~/domain/conversation-bus/ports/conversation-bus.port'
import { WEBHOOK_REGISTRATION_REPOSITORY, type WebhookRegistrationRepository } from '~/domain/webhook/ports/webhook-registration-repository.port'
import { WEBHOOK_DISPATCHER, type WebhookDispatcherPort } from '~/domain/webhook/ports/webhook-dispatcher.port'
import type { NonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'

@Injectable()
export class WebhookDispatchService implements OnModuleInit {
  constructor(
    @Inject(CONVERSATION_BUS)               private readonly bus: ConversationBusPort,
    @Inject(WEBHOOK_REGISTRATION_REPOSITORY) private readonly repo: WebhookRegistrationRepository,
    @Inject(WEBHOOK_DISPATCHER)              private readonly dispatcher: WebhookDispatcherPort,
  ) {}

  onModuleInit() {
    void this.bus.subscribeToConversationStarted(ev => this.onEvent(ev)).toPromise()
  }

  // Contract (matches the JetStream durable-consumer handler):
  //   Task.ok(Unit)        → ACK (no redelivery)
  //   Task.reject(error)   → NAK (redeliver; e.g. Redis down, repo unavailable)
  // Any `failed_after_retries` from the dispatcher is a TERMINAL dispatch outcome —
  // it must trigger conversation termination AND ACK (further redelivery won't
  // change the outcome because the receiver is wedged). Redis/repo INFRA errors
  // reject and redeliver.
  onEvent(event: NonPublicEvent): Task<Unit, Error> {
    return this.repo.findForEvent('conversation.started', event.tenant_id)
      .andThen(regs => fromPromise(this.processRegistrations(event, regs)))
      .mapRejected(e => (e instanceof Error ? e : new Error(String(e))))
  }

  private async processRegistrations(
    event: NonPublicEvent,
    regs: ReadonlyArray<import('~/domain/webhook/entities/webhook-registration.entity').WebhookRegistration>,
  ): Promise<Unit> {
    // Empty registration set is an ACK-with-no-op (not a termination).
    if (regs.length === 0) return Unit

    const results = await Promise.all(
      regs.map(async r => ({ reg: r, res: await this.dispatcher.dispatch(r, event).toPromise() })),
    )

    // Distinguish: infra error (Task rejected → redeliver) vs final failure (Task ok with failed_after_retries → terminate + ACK).
    const infraErrored = results.find(({ res }) => res.isErr)
    if (infraErrored) {
      // Redeliver via NAK by rejecting this Task. SETNX lock protects against duplicate dispatch.
      throw new Error(
        `webhook_dispatch_infra_error: ${infraErrored.res.unwrapErr().message}`,
      )
    }

    const terminal = results
      .map(({ reg, res }) => ({ reg, outcome: res.unwrapOr(null as never) }))
      .filter(({ outcome }) => outcome.outcome === 'failed_after_retries')

    for (const { reg, outcome } of terminal) {
      // Redact userinfo from endpoint_url before putting it on cp.control / logs.
      const safeUrl = this.redactUserinfo(reg.endpoint_url)
      const publishRes = await this.bus
        .requestConversationTermination(
          event.conversation_id,
          'webhook_delivery_failed',
          {
            webhook_id:       reg.webhook_id,
            endpoint_url:     safeUrl,
            last_status_code: (outcome as { last_status_code?: number }).last_status_code,
            attempts:         (outcome as { attempts: number }).attempts,
          },
        )
        .toPromise()
      if (publishRes.isErr) {
        // Termination publish itself failed — do NOT swallow; bubble so NATS redelivers and we retry.
        throw new Error(
          `termination_publish_failed: ${publishRes.unwrapErr().message}`,
        )
      }
    }
    return Unit
  }

  private redactUserinfo(raw: string): string {
    try {
      const u = new URL(raw)
      if (u.username || u.password) {
        u.username = ''; u.password = ''
      }
      return u.toString()
    } catch {
      return raw
    }
  }
}
```

```typescript
// src/service/webhook/webhook.service.module.ts
// Depends on three port tokens (CONVERSATION_BUS, WEBHOOK_REGISTRATION_REPOSITORY,
// WEBHOOK_DISPATCHER). Their providers are registered by AppModule via the
// corresponding outbound modules (ConversationBusOutboundModule,
// WebhookRegistrationOutboundModule, WebhookHttpDispatcherOutboundModule).
// Putting those modules in AppModule's imports (not here) keeps the service
// module pure and avoids a cycle.
import { Module } from '@nestjs/common'
import { WebhookDispatchService } from './webhook-dispatch.service'

@Module({
  providers: [WebhookDispatchService],
  exports:   [WebhookDispatchService],
})
export class WebhookServiceModule {}
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/service/webhook test/service/webhook
git commit -m "feat(CPL-000): add WebhookDispatchService orchestrating fan-out and termination"
```

---

## Phase 7 — Inbound REST controllers (publish + webhook CRUD)

### Task 7.1: Error mapper

The publish DTOs are already created in Phase 0 (`src/inbound/conversation-bus/dto/discriminated-event.dto.ts` + `event-data.dto.ts`). This task adds only the HTTP-problem error mapper used by every controller.

**Files:**
- Create: `src/inbound/conversation-bus/error-mapper.ts`

- [ ] **Step 1: Implement**

```typescript
// src/inbound/conversation-bus/error-mapper.ts
import { HttpException, HttpStatus } from '@nestjs/common'
import {
  EventTypeNotAllowedError,
  UnknownEventTypeError,
  MissingFieldError,
  ConversationBusPublishError,
  ConversationBusObserveError,
} from '~/domain/conversation-bus/errors/conversation-bus.error'

type Problem = Readonly<{ type: string; title: string; status: number; detail?: string; code?: string }>

export const mapError = (err: Error): never => {
  const build = (p: Problem) => { throw new HttpException(p, p.status) }
  if (err instanceof EventTypeNotAllowedError) build({ type: 'about:blank', title: err.name, status: 400, detail: err.message, code: 'event_type_not_allowed_on_verb' })
  if (err instanceof UnknownEventTypeError)   build({ type: 'about:blank', title: err.name, status: 400, detail: err.message, code: 'unknown_event_type' })
  if (err instanceof MissingFieldError)       build({ type: 'about:blank', title: err.name, status: 400, detail: err.message, code: 'missing_field' })
  if (err instanceof ConversationBusPublishError) build({ type: 'about:blank', title: err.name, status: 500, detail: 'Internal server error', code: 'publish_failed' })
  if (err instanceof ConversationBusObserveError) build({ type: 'about:blank', title: err.name, status: 500, detail: 'Internal server error', code: 'observe_failed' })
  build({ type: 'about:blank', title: err.name || 'Error', status: 500, detail: 'Internal server error', code: 'internal_error' })
  throw err // unreachable
}
```

- [ ] **Step 2: Commit**

```
git add src/inbound/conversation-bus/dto src/inbound/conversation-bus/error-mapper.ts
git commit -m "feat(CPL-000): add DTOs and error mapper for conversation-bus inbound"
```

### Task 7.2: `ConversationBusController` — V1/V2/V3 POST

**Files:**
- Create: `src/inbound/conversation-bus/conversation-bus.controller.ts`
- Create: `src/inbound/conversation-bus/conversation-bus.inbound.module.ts`
- Test: `test/inbound/conversation-bus/conversation-bus.controller.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/inbound/conversation-bus/conversation-bus.controller.spec.ts
import { Test } from '@nestjs/testing'
import { INestApplication, ValidationPipe } from '@nestjs/common'
import request from 'supertest'
import { Task, Unit } from 'true-myth'
import { ConversationBusController } from '~/inbound/conversation-bus/conversation-bus.controller'
import { CONVERSATION_BUS } from '~/domain/conversation-bus/ports/conversation-bus.port'

let app: INestApplication
const publishInput  = jest.fn(() => Task.resolve(Unit))
const publishOutput = jest.fn(() => Task.resolve(Unit))
const publishCtrl   = jest.fn(() => Task.resolve(Unit))

beforeAll(async () => {
  const mod = await Test.createTestingModule({
    controllers: [ConversationBusController],
    providers: [
      { provide: CONVERSATION_BUS, useValue: {
        publishParticipantInput: publishInput,
        publishParticipantOutput: publishOutput,
        publishConversationControl: publishCtrl,
      } },
    ],
  }).compile()
  app = mod.createNestApplication()
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }))
  await app.init()
})
afterAll(async () => app.close())

const body = (event_type: string) => ({
  event_id: 'e1', event_type, conversation_id: 'c1', tenant_id: 't1',
  timestamp: 1, version: '1', data: { text: 'hi' },
})

it('V1 rejects message.agent with 400', async () => {
  const r = await request(app.getHttpServer())
    .post('/v1/conversations/c1/participants/p1/legs/l1/input-events')
    .send(body('message.agent'))
  expect(r.status).toBe(400)
})

it('V1 accepts message.user and returns 202', async () => {
  const r = await request(app.getHttpServer())
    .post('/v1/conversations/c1/participants/p1/legs/l1/input-events')
    .send(body('message.user'))
  expect(r.status).toBe(202)
  expect(publishInput).toHaveBeenCalled()
})

it('V2 accepts message.agent and returns 202', async () => {
  const r = await request(app.getHttpServer())
    .post('/v1/conversations/c1/participants/p1/legs/l1/output-events')
    .send(body('message.agent'))
  expect(r.status).toBe(202)
  expect(publishOutput).toHaveBeenCalled()
})

it('V3 accepts conversation.termination-requested', async () => {
  const r = await request(app.getHttpServer())
    .post('/v1/conversations/c1/control-events')
    .send(body('conversation.termination-requested'))
  expect(r.status).toBe(202)
  expect(publishCtrl).toHaveBeenCalled()
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/inbound/conversation-bus/conversation-bus.controller.ts
import { Body, Controller, ForbiddenException, HttpCode, HttpStatus, Inject, Param, Post, UseGuards, UseInterceptors } from '@nestjs/common'
import { ApiHeader, ApiOperation, ApiResponse, ApiTags } from '@nestjs/swagger'
import { LoggerInterceptor } from '@parloa/toolkit'
import { Maybe } from 'true-myth'
import { CONVERSATION_BUS, type ConversationBusPort } from '~/domain/conversation-bus/ports/conversation-bus.port'
import { createNonPublicEvent } from '~/domain/conversation-bus/entities/non-public-event.entity'
import { makeConversationId, makeEventId, makeLegId, makeParticipantId, makeTenantId } from '~/domain/conversation-bus/entities/ids.entity'
import { EventTypeNotAllowedError } from '~/domain/conversation-bus/errors/conversation-bus.error'
import { isAllowedOnVerb, type Verb } from '~/service/conversation-bus/event-type-map'
import { TenantGuard } from '~/inbound/shared/tenant.guard'
import { TenantId } from '~/inbound/shared/tenant-scoped.decorator'
import {
  InputEventPublishDto, OutputEventPublishDto, ControlEventPublishDto,
  MessageUserPublishDto, PingFramePublishDto,
  MessageAgentPublishDto, PongFramePublishDto,
  ConversationTerminationRequestedPublishDto, AddParticipantLegRequestedPublishDto,
} from './dto/discriminated-event.dto'
import { mapError } from './error-mapper'

@UseInterceptors(LoggerInterceptor)
@ApiTags('conversation-bus')
@ApiHeader({ name: 'x-tenant-id', required: true })
@UseGuards(TenantGuard)
@Controller({ path: 'conversations', version: '1' })
export class ConversationBusController {
  constructor(@Inject(CONVERSATION_BUS) private readonly bus: ConversationBusPort) {}

  private assertTenantMatches(headerTenant: string, body: { tenant_id: string }) {
    if (body.tenant_id !== headerTenant) {
      throw new ForbiddenException({
        type: 'about:blank', title: 'TenantMismatch', status: 403, code: 'tenant_mismatch',
      })
    }
  }

  @Post(':cid/participants/:pid/legs/:lid/input-events')
  @HttpCode(HttpStatus.ACCEPTED)
  @ApiOperation({ summary: 'Publish to participant input channel (V1)' })
  @ApiResponse({ status: 202 })
  async publishInput(
    @TenantId() tenantRaw: string,
    @Param('cid') cid: string, @Param('pid') pid: string, @Param('lid') lid: string,
    @Body() body: MessageUserPublishDto | PingFramePublishDto,
  ) {
    this.assertTenantMatches(tenantRaw, body)
    return this.doPublish(cid, pid, lid, body, 'input-events',
      (target, ev) => this.bus.publishParticipantInput(target, ev))
  }

  @Post(':cid/participants/:pid/legs/:lid/output-events')
  @HttpCode(HttpStatus.ACCEPTED)
  @ApiOperation({ summary: 'Publish to participant output channel (V2)' })
  @ApiResponse({ status: 202 })
  async publishOutput(
    @TenantId() tenantRaw: string,
    @Param('cid') cid: string, @Param('pid') pid: string, @Param('lid') lid: string,
    @Body() body: MessageAgentPublishDto | PongFramePublishDto,
  ) {
    this.assertTenantMatches(tenantRaw, body)
    return this.doPublish(cid, pid, lid, body, 'output-events',
      (target, ev) => this.bus.publishParticipantOutput(target, ev))
  }

  @Post(':cid/control-events')
  @HttpCode(HttpStatus.ACCEPTED)
  @ApiOperation({ summary: 'Publish conversation control event (V3)' })
  @ApiResponse({ status: 202 })
  async publishCtrl(
    @TenantId() tenantRaw: string,
    @Param('cid') cid: string,
    @Body() body: ConversationTerminationRequestedPublishDto | AddParticipantLegRequestedPublishDto,
  ) {
    this.assertTenantMatches(tenantRaw, body)
    if (!isAllowedOnVerb(body.event_type, 'control-events'))
      mapError(new EventTypeNotAllowedError(body.event_type, 'control-events'))

    const event = createNonPublicEvent({
      event_id: makeEventId(body.event_id).unwrapOrElse(mapError),
      event_type: body.event_type,
      conversation_id: makeConversationId(cid).unwrapOrElse(mapError),
      tenant_id: makeTenantId(body.tenant_id).unwrapOrElse(mapError),
      participant_id: body.participant_id ? Maybe.just(makeParticipantId(body.participant_id).unwrapOrElse(mapError)) : Maybe.nothing(),
      leg_id: body.leg_id ? Maybe.just(makeLegId(body.leg_id).unwrapOrElse(mapError)) : Maybe.nothing(),
      timestamp: body.timestamp, version: body.version,
      correlation_id: body.correlation_id ? Maybe.just(body.correlation_id) : Maybe.nothing(),
      data: body.data as Record<string, unknown>,
    }).unwrapOrElse(mapError)

    const taskResult = await this.bus.publishConversationControl(event.conversation_id, event)
      .map(() => ({ accepted: true as const, event_id: event.event_id }))
      .toPromise()
    return taskResult.unwrapOrElse(mapError)
  }

  private async doPublish(
    cid: string, pid: string, lid: string,
    body: InputEventPublishDto | OutputEventPublishDto, verb: Verb,
    fn: (t: { conversation_id: string; participant_id: string; leg_id: string }, ev: any) => ReturnType<ConversationBusPort['publishParticipantInput']>,
  ) {
    if (!isAllowedOnVerb(body.event_type, verb))
      mapError(new EventTypeNotAllowedError(body.event_type, verb))

    const event = createNonPublicEvent({
      event_id: makeEventId(body.event_id).unwrapOrElse(mapError),
      event_type: body.event_type,
      conversation_id: makeConversationId(cid).unwrapOrElse(mapError),
      tenant_id: makeTenantId(body.tenant_id).unwrapOrElse(mapError),
      participant_id: Maybe.just(makeParticipantId(pid).unwrapOrElse(mapError)),
      leg_id: Maybe.just(makeLegId(lid).unwrapOrElse(mapError)),
      timestamp: body.timestamp, version: body.version,
      correlation_id: body.correlation_id ? Maybe.just(body.correlation_id) : Maybe.nothing(),
      data: body.data as Record<string, unknown>,
    }).unwrapOrElse(mapError)

    const taskResult = await fn(
      { conversation_id: event.conversation_id, participant_id: pid, leg_id: lid },
      event,
    )
      .map(() => ({ accepted: true as const, event_id: event.event_id }))
      .toPromise()
    return taskResult.unwrapOrElse(mapError)
  }
}
```

```typescript
// src/inbound/conversation-bus/conversation-bus.inbound.module.ts
// Inbound modules do NOT import outbound modules. Controllers depend on the
// CONVERSATION_BUS port token, which is provided globally by AppModule (via
// ConversationBusOutboundModule at the top level). This preserves the hex
// boundary: inbound → domain port ← outbound.
import { Module } from '@nestjs/common'
import { ConversationBusController } from './conversation-bus.controller'

@Module({
  controllers: [ConversationBusController],
})
export class ConversationBusInboundModule {}
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/inbound/conversation-bus/conversation-bus.controller.ts \
        src/inbound/conversation-bus/conversation-bus.inbound.module.ts \
        test/inbound/conversation-bus/conversation-bus.controller.spec.ts
git commit -m "feat(CPL-000): add V1/V2/V3 POST controllers for conversation publish"
```

### Task 7.3: Webhook registration controller (V7a/V7b/V7c)

**Files:**
- Create: `src/inbound/webhook/dto/webhook-registration.dto.ts`
- Create: `src/inbound/webhook/webhook.controller.ts`
- Create: `src/inbound/webhook/webhook.inbound.module.ts`
- Test: `test/inbound/webhook/webhook.controller.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/inbound/webhook/webhook.controller.spec.ts
import { Test } from '@nestjs/testing'
import { INestApplication, ValidationPipe } from '@nestjs/common'
import request from 'supertest'
import { Task, Unit } from 'true-myth'
import { WebhookController } from '~/inbound/webhook/webhook.controller'
import { WEBHOOK_REGISTRATION_REPOSITORY } from '~/domain/webhook/ports/webhook-registration-repository.port'

let app: INestApplication
const repo = {
  create: jest.fn(() => Task.resolve(Unit)),
  list:   jest.fn(() => Task.resolve([])),
  delete: jest.fn(() => Task.resolve(true)),
  findForEvent: jest.fn(),
}

beforeAll(async () => {
  const mod = await Test.createTestingModule({
    controllers: [WebhookController],
    providers: [{ provide: WEBHOOK_REGISTRATION_REPOSITORY, useValue: repo }],
  }).compile()
  app = mod.createNestApplication()
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, transform: true }))
  await app.init()
})
afterAll(async () => app.close())

it('POST /v1/webhooks 201 with conversation.started', async () => {
  const r = await request(app.getHttpServer())
    .post('/v1/webhooks')
    .send({ endpoint_url: 'https://svc/hook', event_types: ['conversation.started'], tenant_id: 't1' })
  expect(r.status).toBe(201)
  expect(repo.create).toHaveBeenCalled()
  expect(r.body).toHaveProperty('webhook_id')
})

it('POST /v1/webhooks 400 on invalid event_types', async () => {
  const r = await request(app.getHttpServer())
    .post('/v1/webhooks')
    .send({ endpoint_url: 'https://svc/hook', event_types: ['message.user'], tenant_id: 't1' })
  expect(r.status).toBe(400)
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/inbound/webhook/dto/webhook-registration.dto.ts
import { ApiProperty } from '@nestjs/swagger'
import { ArrayMinSize, ArrayMaxSize, IsArray, IsOptional, IsString, IsUrl, Length, MaxLength } from 'class-validator'

export class RegisterWebhookDto {
  @ApiProperty()
  @IsUrl({ require_tld: false, protocols: ['https'], require_protocol: true })
  @MaxLength(2048)
  endpoint_url!: string

  @ApiProperty({ type: [String] })
  @IsArray() @ArrayMinSize(1) @ArrayMaxSize(10)
  @IsString({ each: true })
  event_types!: string[]

  // Optional per-webhook secret used for HMAC signing (see Phase 5 dispatcher).
  // Reserved now for forward compatibility. When WEBHOOK_SIGNING_ENABLED is true and
  // a secret is provided, the dispatcher computes sha256(body + '.' + timestamp) keyed
  // by this secret and sends it as X-Parloa-Signature. v1 allows omitting it; the
  // receiver MUST plan to verify when the org rolls out signing.
  @ApiProperty({ required: false })
  @IsOptional() @IsString() @Length(32, 256)
  signing_secret?: string

  // Note: tenant_id is NOT on the DTO. It comes from the trusted X-Tenant-Id header
  // populated by the TenantGuard (see src/inbound/shared/tenant.guard.ts). A body-supplied
  // tenant_id would be a cross-tenant-spoofing vector.
}

export class WebhookRegistrationResponseDto {
  @ApiProperty() webhook_id!: string
  @ApiProperty() tenant_id!: string
  @ApiProperty() endpoint_url!: string
  @ApiProperty({ type: [String] }) event_types!: string[]
  @ApiProperty() created_at!: string
}
```

```typescript
// src/inbound/webhook/webhook.controller.ts
import { randomUUID } from 'node:crypto'
import {
  Body, Controller, Delete, ForbiddenException, Get, HttpCode, HttpStatus, Inject, NotFoundException,
  Param, Post, UseGuards,
} from '@nestjs/common'
import { ApiHeader, ApiOperation, ApiResponse, ApiTags } from '@nestjs/swagger'
import { WEBHOOK_REGISTRATION_REPOSITORY, type WebhookRegistrationRepository } from '~/domain/webhook/ports/webhook-registration-repository.port'
import { createWebhookRegistration, makeWebhookId, type WebhookRegistration } from '~/domain/webhook/entities/webhook-registration.entity'
import { makeTenantId } from '~/domain/conversation-bus/entities/ids.entity'
import { TenantGuard } from '~/inbound/shared/tenant.guard'
import { TenantId } from '~/inbound/shared/tenant-scoped.decorator'
import { mapError } from '~/inbound/conversation-bus/error-mapper'
import { assertSafeHttpUrl } from '~/outbound/webhook/http/safe-url.validator'
import { RegisterWebhookDto, WebhookRegistrationResponseDto } from './dto/webhook-registration.dto'

const WEBHOOK_ID_REGEX = /^wh_[A-Za-z0-9-]{1,80}$/

const toResponse = (r: WebhookRegistration): WebhookRegistrationResponseDto => ({
  webhook_id: r.webhook_id,
  tenant_id: r.tenant_id,
  endpoint_url: r.endpoint_url,
  event_types: [...r.event_types],
  created_at: r.created_at.toISOString(),
})

@ApiTags('webhooks')
@ApiHeader({ name: 'x-tenant-id', required: true, description: 'Caller tenant id (set by ingress)' })
@UseGuards(TenantGuard)
@Controller({ path: 'webhooks', version: '1' })
export class WebhookController {
  constructor(@Inject(WEBHOOK_REGISTRATION_REPOSITORY) private readonly repo: WebhookRegistrationRepository) {}

  @Post()
  @HttpCode(HttpStatus.CREATED)
  @ApiOperation({ summary: 'Register a webhook (V7a)' })
  @ApiResponse({ status: 201, type: WebhookRegistrationResponseDto })
  async register(
    @TenantId() tenantRaw: string,
    @Body() dto: RegisterWebhookDto,
  ): Promise<WebhookRegistrationResponseDto> {
    const urlCheck = assertSafeHttpUrl(dto.endpoint_url, {
      allowedSchemes: ['https'],
      allowedHostSuffixes: ['.internal.parloa.com'], // config-driven in production
    })
    if (urlCheck.isErr) {
      throw new ForbiddenException({
        type: 'about:blank',
        title: 'EndpointUrlRejected',
        status: 403,
        code: `ssrf_blocked:${urlCheck.unwrapErr().code}`,
      })
    }

    const reg = createWebhookRegistration({
      webhook_id: makeWebhookId(`wh_${randomUUID()}`).unwrapOrElse(mapError),
      tenant_id: makeTenantId(tenantRaw).unwrapOrElse(mapError),
      endpoint_url: dto.endpoint_url,
      event_types: dto.event_types,
      created_at: new Date(),
    }).unwrapOrElse(mapError)
    const r = await this.repo.create(reg).toPromise()
    return r.match({ Ok: () => toResponse(reg), Err: mapError })
  }

  // No caller-supplied tenant_id — always the caller's own (from TenantGuard).
  @Get()
  @ApiOperation({ summary: 'List webhooks for the caller tenant (V7b)' })
  async list(@TenantId() tenantRaw: string): Promise<WebhookRegistrationResponseDto[]> {
    const r = await this.repo.list(makeTenantId(tenantRaw).unwrapOrElse(mapError)).toPromise()
    return r.match({ Ok: arr => arr.map(toResponse), Err: mapError })
  }

  @Delete(':webhook_id')
  @HttpCode(HttpStatus.NO_CONTENT)
  @ApiOperation({ summary: 'Unregister a webhook (V7c)' })
  async unregister(
    @TenantId() tenantRaw: string,
    @Param('webhook_id') webhook_id: string,
  ): Promise<void> {
    if (!WEBHOOK_ID_REGEX.test(webhook_id)) {
      throw new NotFoundException({
        type: 'about:blank', title: 'WebhookNotFound', status: 404, code: 'webhook_not_found',
      })
    }
    // Tenant-ownership check: load by id, compare to caller tenant, then delete.
    const tenant = makeTenantId(tenantRaw).unwrapOrElse(mapError)
    const ownedRes = await this.repo.list(tenant).toPromise()
    const owned = ownedRes.unwrapOr([] as ReadonlyArray<WebhookRegistration>)
    if (!owned.some(r => r.webhook_id === webhook_id)) {
      // Do not distinguish "not yours" from "not found" to avoid an enumeration oracle.
      throw new NotFoundException({
        type: 'about:blank', title: 'WebhookNotFound', status: 404, code: 'webhook_not_found',
      })
    }
    const del = await this.repo.delete(makeWebhookId(webhook_id).unwrapOrElse(mapError)).toPromise()
    del.match({ Ok: () => undefined, Err: mapError })
  }
}
```

```typescript
// src/inbound/webhook/webhook.inbound.module.ts
// See comment in conversation-bus.inbound.module.ts — outbound is not imported here.
import { Module } from '@nestjs/common'
import { WebhookController } from './webhook.controller'

@Module({
  controllers: [WebhookController],
})
export class WebhookInboundModule {}
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/inbound/webhook test/inbound/webhook
git commit -m "feat(CPL-000): add V7a/V7b/V7c webhook registration controller"
```

---

## Phase 8 — Inbound SSE controllers (V4, V5)

### Task 8.1: SSE stream operator + connection cap

Use NestJS's native `@Sse()` decorator — the controller returns `Observable<MessageEvent>`, framework handles headers, interceptors stay in the pipeline. The bounded-buffer + critical-event-terminate behavior is an RxJS operator we compose into the stream.

**Files:**
- Create: `src/inbound/conversation-bus/sse-operators.ts` — `criticalBoundedBuffer` operator + `SseConnectionCounter`
- Test: `test/inbound/conversation-bus/sse-operators.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/inbound/conversation-bus/sse-operators.spec.ts
import { Subject, firstValueFrom, toArray } from 'rxjs'
import { take } from 'rxjs/operators'
import { Result } from 'true-myth'
import { criticalBoundedBuffer, SseConnectionCounter } from '~/inbound/conversation-bus/sse-operators'

it('passes events through under buffer size', async () => {
  const src = new Subject<Result<any, Error>>()
  const onTerminate = jest.fn()
  const stream$ = src.pipe(criticalBoundedBuffer({ bufferSize: 8, criticalEventTypes: new Set(['message.user']), onTerminate }))
  const collected = firstValueFrom(stream$.pipe(take(2), toArray()))
  src.next(Result.ok({ event_type: 'message.agent', data: { text: 'a' } }))
  src.next(Result.ok({ event_type: 'message.agent', data: { text: 'b' } }))
  expect((await collected).length).toBe(2)
  expect(onTerminate).not.toHaveBeenCalled()
})

it('emits terminal error + calls onTerminate when a critical event arrives with buffer full', async () => {
  // The operator maintains a rolling buffer representing not-yet-consumed events.
  // To exercise the critical path we simulate a slow consumer by not subscribing until after N events.
  const src = new Subject<Result<any, Error>>()
  const onTerminate = jest.fn()
  const received: any[] = []
  const sub = src
    .pipe(criticalBoundedBuffer({ bufferSize: 2, criticalEventTypes: new Set(['message.user']), onTerminate }))
    .subscribe({ next: e => received.push(e), complete: () => {} })
  // Overflow: push 3 non-critical then 1 critical while buffer is full.
  src.next(Result.ok({ event_type: 'message.agent', data: { text: '1' } }))
  src.next(Result.ok({ event_type: 'message.agent', data: { text: '2' } }))
  src.next(Result.ok({ event_type: 'message.agent', data: { text: '3' } })) // dropped (non-critical)
  src.next(Result.ok({ event_type: 'message.user', data: { text: 'critical' } }))
  await new Promise(r => setImmediate(r))
  sub.unsubscribe()
  expect(onTerminate).toHaveBeenCalledWith('sse_critical_event_undeliverable', 'message.user')
  const terminal = received[received.length - 1]
  expect(terminal.data.code).toBe('sse_delivery_failed')
})

describe('SseConnectionCounter', () => {
  it('rejects acquire when at cap', () => {
    const c = new SseConnectionCounter(2)
    expect(c.acquire()).toBe(true)
    expect(c.acquire()).toBe(true)
    expect(c.acquire()).toBe(false)
    c.release()
    expect(c.acquire()).toBe(true)
  })
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/inbound/conversation-bus/sse-operators.ts
import { MessageEvent } from '@nestjs/common'
import { Observable, OperatorFunction } from 'rxjs'
import { Result } from 'true-myth'

export class SseConnectionCounter {
  private current = 0
  constructor(private readonly cap: number) {}
  acquire(): boolean {
    if (this.current >= this.cap) return false
    this.current += 1
    return true
  }
  release(): void {
    if (this.current > 0) this.current -= 1
  }
  get active(): number { return this.current }
}

type BufferOpts<T extends { event_type: string }> = Readonly<{
  bufferSize:          number
  criticalEventTypes:  ReadonlySet<string>
  onTerminate?:        (reason: string, criticalEventType: string) => void
  onDrop?:             (eventType: string) => void
}>

// criticalBoundedBuffer: each upstream `Result<T, Error>` either
//   - passes through as a MessageEvent when the consumer can keep up (in-flight count < bufferSize)
//   - gets silently dropped when buffer is full AND event is non-critical (increments drop counter)
//   - emits a terminal `error` MessageEvent + calls onTerminate + completes when buffer is full AND event is critical
// The "buffer" here represents the queue of events not-yet-consumed-by-the-HTTP-writer.
// RxJS's default is lossless — we explicitly apply backpressure.
export const criticalBoundedBuffer = <T extends { event_type: string }>(
  opts: BufferOpts<T>,
): OperatorFunction<Result<T, Error>, MessageEvent> =>
  (src) => new Observable<MessageEvent>(subscriber => {
    let inFlight = 0

    const mark = (): void => {
      inFlight += 1
    }
    const unmark = (): void => {
      if (inFlight > 0) inFlight -= 1
    }

    const sub = src.subscribe({
      next: r => r.match({
        Ok: ev => {
          if (inFlight >= opts.bufferSize) {
            if (opts.criticalEventTypes.has(ev.event_type)) {
              subscriber.next({
                type: 'message',
                data: { code: 'sse_delivery_failed', critical_event_type: ev.event_type },
              })
              opts.onTerminate?.('sse_critical_event_undeliverable', ev.event_type)
              subscriber.complete()
              return
            }
            opts.onDrop?.(ev.event_type)
            return
          }
          mark()
          // Wrap the event so the subscriber can decrement inFlight when the HTTP writer drains it.
          // NestJS @Sse() writes synchronously per emission, so decrement on the next tick is safe.
          subscriber.next({ type: 'message', data: ev })
          queueMicrotask(unmark)
        },
        Err: () => {
          // Non-fatal translation/observe error — drop and continue.
          opts.onDrop?.('error')
        },
      }),
      error: err => subscriber.error(err),
      complete: () => subscriber.complete(),
    })
    return () => sub.unsubscribe()
  })
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/inbound/conversation-bus/sse-operators.ts \
        test/inbound/conversation-bus/sse-operators.spec.ts
git commit -m "feat(CPL-000): add RxJS critical-event bounded-buffer operator and SSE connection counter"
```

### Task 8.2: V4 + V5 SSE controllers

**Files:**
- Create: `src/inbound/conversation-bus/conversation-observe.controller.ts`
- Modify: `src/inbound/conversation-bus/conversation-bus.inbound.module.ts`
- Test: `test/inbound/conversation-bus/conversation-observe.controller.spec.ts`

- [ ] **Step 1: Failing test**

```typescript
// test/inbound/conversation-bus/conversation-observe.controller.spec.ts
import { Test } from '@nestjs/testing'
import { INestApplication } from '@nestjs/common'
import request from 'supertest'
import { Subject } from 'rxjs'
import { Result } from 'true-myth'
import { ConversationObserveController } from '~/inbound/conversation-bus/conversation-observe.controller'
import { CONVERSATION_BUS } from '~/domain/conversation-bus/ports/conversation-bus.port'

let app: INestApplication
const stream$ = new Subject<Result<any, Error>>()
const bus = {
  observeConversation: () => stream$,
  observeConversationControl: () => stream$,
}

beforeAll(async () => {
  const mod = await Test.createTestingModule({
    controllers: [ConversationObserveController],
    providers: [{ provide: CONVERSATION_BUS, useValue: bus }],
  }).compile()
  app = mod.createNestApplication()
  await app.init()
})
afterAll(async () => app.close())

it('GET /v1/conversations/c1/events streams SSE events', (done) => {
  const req = request(app.getHttpServer())
    .get('/v1/conversations/c1/events')
    .buffer(true)
    .parse((res, cb) => {
      let chunks = ''
      res.on('data', (d: Buffer) => {
        chunks += d.toString()
        if (chunks.includes('message.agent')) { res.destroy(); cb(null, chunks) }
      })
      res.on('error', e => cb(e, null))
    })
    .end((err, res) => {
      if (err && !res) return done(err)
      expect(res.body as string).toMatch(/"event_type":"message.agent"/)
      done()
    })

  setTimeout(() => stream$.next(Result.ok({ event_type: 'message.agent', data: { text: 'ok' } })), 50)
})
```

- [ ] **Step 2: Run** — FAIL.

- [ ] **Step 3: Implement**

```typescript
// src/inbound/conversation-bus/conversation-observe.controller.ts
import { Controller, HttpException, HttpStatus, Inject, Param, Sse, UseGuards } from '@nestjs/common'
import { ApiHeader, ApiOperation, ApiTags } from '@nestjs/swagger'
import type { MessageEvent } from '@nestjs/common'
import { ConfigService } from '@nestjs/config'
import { finalize, Observable } from 'rxjs'
import { CONVERSATION_BUS, type ConversationBusPort } from '~/domain/conversation-bus/ports/conversation-bus.port'
import { makeConversationId, makeLegId, makeParticipantId } from '~/domain/conversation-bus/entities/ids.entity'
import { conversationScope, legScope, participantScope } from '~/domain/conversation-bus/entities/observe-scope.entity'
import { CRITICAL_EVENT_TYPES } from '~/service/conversation-bus/event-type-map'
import { TenantGuard } from '~/inbound/shared/tenant.guard'
import { criticalBoundedBuffer, SseConnectionCounter } from './sse-operators'
import { mapError } from './error-mapper'

@ApiTags('conversation-bus')
@ApiHeader({ name: 'x-tenant-id', required: true })
@UseGuards(TenantGuard)
@Controller({ path: 'conversations', version: '1' })
export class ConversationObserveController {
  private readonly counter: SseConnectionCounter
  private readonly bufferSize: number

  constructor(
    @Inject(CONVERSATION_BUS) private readonly bus: ConversationBusPort,
    private readonly config: ConfigService,
  ) {
    this.counter = new SseConnectionCounter(
      this.config.get<number>('NONPUBLIC_SSE_MAX_CONNECTIONS', 1000),
    )
    this.bufferSize = this.config.get<number>('NONPUBLIC_SSE_BUFFER_EVENTS', 256)
  }

  private buildStream(
    source$: Observable<import('true-myth').Result<any, Error>>,
    conversationIdBranded: never,
  ): Observable<MessageEvent> {
    if (!this.counter.acquire()) {
      throw new HttpException(
        { type: 'about:blank', title: 'TooManyConnections', status: 429, code: 'sse_connection_limit' },
        HttpStatus.TOO_MANY_REQUESTS,
      )
    }
    return source$.pipe(
      criticalBoundedBuffer({
        bufferSize:         this.bufferSize,
        criticalEventTypes: CRITICAL_EVENT_TYPES,
        onTerminate:        (reason, ct) => {
          void this.bus
            .requestConversationTermination(
              conversationIdBranded,
              reason,
              { critical_event_type: ct },
            )
            .toPromise()
            .then(r => r.isErr && console.error('termination publish failed', r.unwrapErr()))
        },
        onDrop:             () => { /* metrics hook — see Phase 9 observability */ },
      }),
      finalize(() => this.counter.release()),
    )
  }
  constructor(@Inject(CONVERSATION_BUS) private readonly bus: ConversationBusPort) {}

  @Sse(':cid/events')
  @ApiOperation({ summary: 'Observe conversation (V4, conversation scope)' })
  conversation(@Param('cid') cid: string): Observable<MessageEvent> {
    const cidB = makeConversationId(cid).unwrapOrElse(mapError)
    return this.buildStream(this.bus.observeConversation(conversationScope(cidB)), cidB as never)
  }

  @Sse(':cid/participants/:pid/events')
  @ApiOperation({ summary: 'Observe conversation (V4, participant scope)' })
  participant(@Param('cid') cid: string, @Param('pid') pid: string): Observable<MessageEvent> {
    const cidB = makeConversationId(cid).unwrapOrElse(mapError)
    const pidB = makeParticipantId(pid).unwrapOrElse(mapError)
    return this.buildStream(this.bus.observeConversation(participantScope(cidB, pidB)), cidB as never)
  }

  @Sse(':cid/participants/:pid/legs/:lid/events')
  @ApiOperation({ summary: 'Observe conversation (V4, leg scope)' })
  leg(
    @Param('cid') cid: string,
    @Param('pid') pid: string,
    @Param('lid') lid: string,
  ): Observable<MessageEvent> {
    const cidB = makeConversationId(cid).unwrapOrElse(mapError)
    const pidB = makeParticipantId(pid).unwrapOrElse(mapError)
    const lidB = makeLegId(lid).unwrapOrElse(mapError)
    return this.buildStream(this.bus.observeConversation(legScope(cidB, pidB, lidB)), cidB as never)
  }

  @Sse(':cid/control-events')
  @ApiOperation({ summary: 'Observe conversation control (V5)' })
  control(@Param('cid') cid: string): Observable<MessageEvent> {
    const cidB = makeConversationId(cid).unwrapOrElse(mapError)
    return this.buildStream(this.bus.observeConversationControl(cidB), cidB as never)
  }
}
```

```typescript
// append controller to src/inbound/conversation-bus/conversation-bus.inbound.module.ts controllers[]
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit**

```
git add src/inbound/conversation-bus/conversation-observe.controller.ts \
        src/inbound/conversation-bus/conversation-bus.inbound.module.ts \
        test/inbound/conversation-bus/conversation-observe.controller.spec.ts
git commit -m "feat(CPL-000): add V4/V5 SSE controllers with critical-event termination"
```

---

## Phase 9 — App wiring, env, /v1 migration of watchdog

### Task 9.0: Observability metrics registration (F20)

Spec §Observability requires 7 named metrics. Register them in `MetricsModule.forRoot` in `app.module.ts` (mirror the watchdog pattern already in place).

**Files:**
- Modify: `src/app.module.ts` — extend `MetricsModule.forRoot({ metrics: [...] })`

- [ ] **Step 1:** Append these entries to the existing `metrics` array (keep the watchdog ones):

```typescript
{
  name: 'conversation_gateway.webhook.delivery_attempt_total',
  type: 'counter',
  description: Maybe.just('Webhook delivery attempts (includes retries)'),
  unit: Maybe.nothing(),
  valueType: Maybe.just('int' as const),
},
{
  name: 'conversation_gateway.webhook.delivery_failure_total',
  type: 'counter',
  description: Maybe.just('Webhook deliveries that exhausted retries'),
  unit: Maybe.nothing(),
  valueType: Maybe.just('int' as const),
},
{
  name: 'conversation_gateway.webhook.delivery_latency_seconds',
  type: 'histogram',
  description: Maybe.just('Wall-clock webhook dispatch latency'),
  unit: Maybe.just(SEMCONV_UNITS.SECONDS),
  valueType: Maybe.just('double' as const),
},
{
  name: 'conversation_gateway.sse.connections_active',
  type: 'histogram',   // histogram over connection counts per pod sample
  description: Maybe.just('Active SSE connections per pod'),
  unit: Maybe.nothing(),
  valueType: Maybe.just('int' as const),
},
{
  name: 'conversation_gateway.sse.events_sent_total',
  type: 'counter',
  description: Maybe.just('SSE events written to consumers'),
  unit: Maybe.nothing(),
  valueType: Maybe.just('int' as const),
},
{
  name: 'conversation_gateway.sse.drop_total',
  type: 'counter',
  description: Maybe.just('SSE events dropped due to slow consumer'),
  unit: Maybe.nothing(),
  valueType: Maybe.just('int' as const),
},
{
  name: 'conversation_gateway.sse.termination_triggered_total',
  type: 'counter',
  description: Maybe.just('Conversations terminated due to SSE critical-event undeliverability'),
  unit: Maybe.nothing(),
  valueType: Maybe.just('int' as const),
},
{
  name: 'conversation_gateway.event_translation.drop_total',
  type: 'counter',
  description: Maybe.just('Events dropped in translation (unmapped internal name, missing fields)'),
  unit: Maybe.nothing(),
  valueType: Maybe.just('int' as const),
},
```

- [ ] **Step 2:** In `WebhookHttpDispatcher`, `WebhookDispatchService`, `EventTranslationService`, and `criticalBoundedBuffer`, inject the corresponding meter via the toolkit's `@InjectMetric(...)` and increment/observe at the relevant points. Every code location flagged with "metrics hook" comments in earlier tasks becomes a real call here.

- [ ] **Step 3:** Add OTel tracing spans: every webhook POST gets a span with `webhook.id`, `webhook.event_type`, `webhook.endpoint.host`, `webhook.status_code` attributes. SSE connections get open/close spans. Build on the parent correlation from the triggering event (`event.correlation_id`).

- [ ] **Step 4: Commit**

```
git add src/app.module.ts src/outbound/webhook src/service/webhook src/inbound/conversation-bus src/service/conversation-bus
git commit -m "feat(CPL-000): register conversation-gateway metrics and instrument dispatch/SSE/translation paths"
```

### Task 9.1: Env schema additions

**Files:**
- Modify: `src/app.module.ts`

- [ ] **Step 1: Update Joi schema**

Add to the `validationSchema` object (keep existing keys):

```typescript
// in src/app.module.ts
NONPUBLIC_SSE_BUFFER_EVENTS:      Joi.number().integer().min(1).default(256),
NONPUBLIC_SSE_MAX_CONNECTIONS:    Joi.number().integer().min(1).default(1000),
NONPUBLIC_CP_CONTROL_STREAMS:     Joi.string().default('cp-control,cp-control-external'),
WEBHOOK_ALLOWED_SCHEMES:          Joi.string().default('https'),
WEBHOOK_ALLOWED_HOST_SUFFIXES:    Joi.string().default('.internal.parloa.com'),
WEBHOOK_SIGNING_ENABLED:          Joi.boolean().default(false),
WEBHOOK_DISPATCH_PUBLISH_BODYCAP: Joi.string().default('64kb'),
WEBHOOK_REGISTRATION_BODYCAP:     Joi.string().default('4kb'),
```

- [ ] **Step 2: Wire modules into AppModule imports**

AppModule owns the cross-cutting module graph. Order matters: outbound modules (which provide port tokens) go BEFORE any service/inbound module that depends on them. Service modules provide shared services. Inbound modules only bring controllers.

```typescript
// add imports[] entries in app.module.ts
import { ConversationBusDomainModule } from '~/domain/conversation-bus/conversation-bus.domain.module'
import { WebhookDomainModule } from '~/domain/webhook/webhook.domain.module'
import { ConversationBusServiceModule } from '~/service/conversation-bus/conversation-bus.service.module'
import { ConversationBusOutboundModule } from '~/outbound/conversation-bus/nats/conversation-bus.outbound.module'
import { WebhookRegistrationOutboundModule } from '~/outbound/webhook/redis/webhook-registration.outbound.module'
import { WebhookHttpDispatcherOutboundModule } from '~/outbound/webhook/http/webhook-http-dispatcher.outbound.module'
import { WebhookServiceModule } from '~/service/webhook/webhook.service.module'

// in AppModule imports[] (append in this order — providers before consumers):
ConversationBusDomainModule,
WebhookDomainModule,
ConversationBusServiceModule,           // provides EventTranslationService
ConversationBusOutboundModule,          // provides CONVERSATION_BUS
WebhookRegistrationOutboundModule,      // provides WEBHOOK_REGISTRATION_REPOSITORY
WebhookHttpDispatcherOutboundModule,    // provides WEBHOOK_DISPATCHER
WebhookServiceModule,                   // consumes all three tokens above
```

- [ ] **Step 3: Wire inbound modules into `src/inbound/inbound.module.ts`**

```typescript
// modify src/inbound/inbound.module.ts
import { ConversationBusInboundModule } from './conversation-bus/conversation-bus.inbound.module'
import { WebhookInboundModule } from './webhook/webhook.inbound.module'

@Module({ imports: [/* existing */, ConversationBusInboundModule, WebhookInboundModule] })
export class InboundModule {}
```

- [ ] **Step 4: Start the app locally (dev compose), hit `/v1/webhooks` with a GET — expect 200 + []**
- [ ] **Step 5: Commit**

```
git add src/app.module.ts src/inbound/inbound.module.ts
git commit -m "feat(CPL-000): wire conversation-bus and webhook modules into AppModule"
```

### Task 9.2: Move watchdog controllers under `/v1/` prefix

**Files:**
- Modify: `src/inbound/watchdog/watchdog.controller.ts`

- [ ] **Step 1: Change decorators**

```typescript
// src/inbound/watchdog/watchdog.controller.ts
@Controller({ path: 'conversations', version: '1' })  // was version: '0'
// also for HeartbeatController:
@Controller({ path: 'heartbeats', version: '1' })
```

- [ ] **Step 2: Update existing watchdog tests** (path prefix `/v1/` where they previously hit `/v0/`).
- [ ] **Step 3: Run full watchdog test suite** — PASS.
- [ ] **Step 4: Commit**

```
git add src/inbound/watchdog/watchdog.controller.ts test/
git commit -m "chore(CPL-000): move watchdog controllers under /v1 for API-surface consistency"
```

---

## Phase 10 — End-to-end tests

### Task 10.1: e2e harness

**Files:**
- Create: `test/e2e/setup.ts`

- [ ] **Step 1: Implement harness that spins NATS + Redis containers, builds the Nest app, returns `{ app, nc, redis, nats }`.** (Pattern copied from `cpl-websocket-bridge/test/e2e/helpers/`.)
- [ ] **Step 2: Commit**

```
git add test/e2e/setup.ts
git commit -m "test(CPL-000): add e2e harness spinning NATS and Redis containers"
```

### Task 10.2: Publish + SSE e2e

- [ ] **Step 1: Write `test/e2e/conversation-bus.e2e-spec.ts` covering:**
  - POST V1 `input-events` → raw NATS subscriber sees internal `UserMessage` on `conversation.c1.p1.channel.in`.
  - POST V2 `output-events` → raw NATS subscriber sees internal `AgentMessage` on `conversation.c1.p1.channel.out`.
  - GET V4 `/v1/conversations/c1/events` — publish internal `AgentMessage` via raw NATS; SSE consumer receives translated non-public event.
  - GET V5 `/v1/conversations/c1/control-events` — publish internal `ConversationTerminationRequested`; SSE receives translated event.

- [ ] **Step 2: Run** — PASS.
- [ ] **Step 3: Commit**

```
git add test/e2e/conversation-bus.e2e-spec.ts
git commit -m "test(CPL-000): e2e for publish and SSE observe paths"
```

### Task 10.3: Webhook dispatch e2e — registration, single-firing, termination on failure

- [ ] **Step 1: Write `test/e2e/webhook-dispatch.e2e-spec.ts` covering:**
  - Register via POST /v1/webhooks.
  - Publish `ConversationStartedEvent` to `cp.control` via raw JetStream; assert the registered endpoint receives exactly one POST.
  - Run with two gateway instances sharing Redis + NATS (spawn a second Nest app on a different port with `--inspect` style); assert still exactly one POST.
  - Register a webhook pointing at an always-500 endpoint; publish `ConversationStartedEvent`; within 15 s observe `conversation-termination-requested` on `cp.control` with reason `webhook_delivery_failed`.

- [ ] **Step 2: Run** — PASS.
- [ ] **Step 3: Commit**

```
git add test/e2e/webhook-dispatch.e2e-spec.ts
git commit -m "test(CPL-000): e2e for webhook single-firing and termination on failure"
```

### Task 10.4: Critical-event SSE → termination e2e

- [ ] **Step 1: Write a test that connects to SSE but drains slowly; publish 257 `UserMessage` events; assert:**
  - SSE consumer receives a terminal `error` event with code `sse_delivery_failed`.
  - `conversation.termination-requested` is observed on `cp.control`.

- [ ] **Step 2: Run** — PASS.
- [ ] **Step 3: Commit**

```
git add test/e2e/conversation-bus.e2e-spec.ts
git commit -m "test(CPL-000): e2e for critical-event SSE overflow termination"
```

---

## Phase 11 — OpenAPI alignment & README

### Task 11.1: Swagger decorator audit

**Files:**
- Modify controller files as needed to ensure `@ApiTags`, `@ApiOperation`, `@ApiBody`, `@ApiResponse` match `docs/api/openapi_non_public_v1.yaml`. Add `@ApiExtraModels(NonPublicEventDto, ...)` to module registrations.

**OpenAPI source of truth (F13 decision)**: the **hand-written YAML** at `docs/api/openapi_non_public_v1.yaml` is canonical. Swagger decorators exist to produce the same runtime /docs experience, but on any conflict the YAML wins. A CI contract test diffs the generated `/docs-json` against the YAML and fails the build on drift.

- [ ] **Step 1: Enable Swagger UI at `/docs`** in `src/main.ts`. Open `http://localhost:3000/docs` locally and verify endpoints + schemas.
- [ ] **Step 2: Write a CI contract test** (`test/contract/openapi-contract.spec.ts`) that loads `docs/api/openapi_non_public_v1.yaml`, spins up the Nest app with Swagger, fetches `/docs-json`, and compares path + schema shapes (not descriptions). Fail the test on any shape-level drift.
- [ ] **Step 3: If the test fails now, fix decorators to match the YAML** (not the other way around).
- [ ] **Step 4: Commit**

```
git commit -am "chore(CPL-000): align Swagger decorators with OpenAPI source of truth"
```

### Task 11.2: README + runbook notes

- [ ] **Step 1: Append to `README.md`** a "Non-Public API" section pointing to the design spec and OpenAPI file, with sample `curl` invocations for V1/V4/V7a.
- [ ] **Step 2: Commit**

```
git add README.md
git commit -m "docs(CPL-000): add Non-Public API section to README"
```

---

## Phase 12 — Final verification

### Task 12.1: Full CI locally

- [ ] **Step 1:** `pnpm lint` — PASS
- [ ] **Step 2:** `pnpm test` — PASS (unit + integration via testcontainers)
- [ ] **Step 3:** `pnpm test:e2e` — PASS
- [ ] **Step 4: Push branch and open PR** against the existing design-spec PR #17 base, OR open fresh PR against `main` referencing #17.

---

## Implementation-time decisions (notes, not tasks)

- **Webhook signing rollout.** DTO carries an optional `signing_secret`; dispatcher emits `X-Parloa-Signature` + `X-Parloa-Timestamp` when `WEBHOOK_SIGNING_ENABLED=true`. Default OFF in v1. Flip on before any non-CP consumer with higher trust requirements onboards.
- **TenantGuard trust source.** v1 trusts the `X-Tenant-Id` header populated at cluster ingress. Replace with mTLS/JWT before the second non-CP consumer class onboards — tracked ticket required before production rollout.
- **SETNX TTL vs NATS redelivery window.** SETNX TTL is 120s, which covers NATS `maxDeliver × ackWaitSeconds = 3 × 15s = 45s` with headroom. If either value changes, keep TTL ≥ 2× the product.
- **Redis-unavailable runbook (F17).** When Redis is down, `WebhookHttpDispatcher.dispatch` rejects → JetStream redelivers up to `maxDeliver: 3` → TERMs. No conversation-termination fires in that path. The runbook must alert on `conversation_gateway.webhook.delivery_attempt_total{status!=2xx}` and `redis_ping_failures_total`. Operators should know: "if Redis is red, conversations may be started without webhooks and no termination follows."
- **`tenant_id` location in internal `ConversationStarted` envelopes (F10).** Translation assumes `tenant_id` is at the top level of the internal envelope (per `envelope.yaml` in `pbc-communications-platform`). Task 2.3 adds a contract test (`test/service/conversation-bus/contract/conversation-started-envelope.contract.spec.ts`) that loads the real internal schema from `pbc-communications-platform/docs/interfaces/schemas/conversation-started.yaml` (or a checked-in snapshot) and asserts `toNonPublic` yields a non-Nothing `NonPublicEvent` with the expected `tenant_id`. If that test fails when the real stream is migrated, the translation needs to dig into `payload.tenant_id`.
- **SSE connection cap (F25).** `NONPUBLIC_SSE_MAX_CONNECTIONS` defaults to 1000/pod; tune once real consumers connect. `@Throttle` on publish endpoints is NOT in v1 — add once a publishing consumer exists.
- **ARP-error mirroring gap.** ARP publishes transient/fatal errors to `cp.control` but not to `conversation.{id}.control`. Non-CP SSE observers therefore miss them. Preferred fix: change ARP to publish on both. Out of v1 scope for this API but must be a linked ticket.

## Self-review notes

- **Trust boundary** is established in Phase 0 and applied everywhere:
  - `TenantGuard` + `@TenantId()` — every inbound controller (V1–V7) is `@UseGuards(TenantGuard)`; no endpoint accepts a caller-supplied `tenant_id` that isn't verified against the header.
  - `assertSafeHttpUrl` + `resolveToSafeTarget` — webhook `endpoint_url` is scheme-checked, userinfo-rejected, private/loopback-blocked, and DNS-pinned at registration time AND again at dispatch time (rebinding defense). Dispatcher POSTs to the pinned IP with the original `Host` header.
  - Discriminated per-`event_type` DTOs with `@ValidateNested` + `@Type` + global `forbidNonWhitelisted: true` — the inbound `data` schema enforces `additionalProperties: false` runtime-equivalent.
  - Leak-stripping is an **allowlist** (`ALLOWED_PAYLOAD_FIELDS`) — no internal field reaches a consumer unless explicitly enumerated. CI invariant test enforces coverage across every mapped internal name.
- Every public symbol referenced in later tasks appears in an earlier task: `CONVERSATION_BUS` token (Task 1.5), `WEBHOOK_DISPATCHER` token (Task 1.6), `EventTranslationService` (Task 2.3), subject templates constants (Task 2.1), `CRITICAL_EVENT_TYPES` + `ALLOWED_PAYLOAD_FIELDS` (Task 2.2), `TenantGuard`/`@TenantId()` (Task 0.1), `assertSafeHttpUrl`/`resolveToSafeTarget` (Task 0.2), discriminated DTOs (Task 0.3), `makeWebhookId` (Task 1.6).
- Every spec section has at least one task:
  - V1/V2/V3 publish → Task 7.2.
  - V4/V5 observe → Tasks 8.1, 8.2.
  - V6 webhook delivery → Tasks 3.2, 5.1, 6.1.
  - V7a/V7b/V7c registration → Tasks 4.1, 7.3.
  - Error model / critical events / termination → Tasks 8.1, 8.2, 6.1, 10.3, 10.4.
  - Scalability (Redis SETNX, durable JetStream) → Tasks 5.1, 3.2.
  - Leak-stripping contract → Task 2.3 (+ fixture).
  - Out-of-v1: cp-control publish (not implemented), audio frames (translation omits them by design), ARP-error mirroring (tracked in spec open questions).
- Placeholders: none. Every step shows the exact code.
- Type consistency: `NonPublicEvent`, `ConversationId`, `ObserveScope`, `ParticipantLegTarget`, `WebhookRegistration`, `DispatchResult`, `ConversationBusPort`, `WebhookRegistrationRepository`, `WebhookDispatcherPort` are all defined once and referenced under their exact names downstream.
