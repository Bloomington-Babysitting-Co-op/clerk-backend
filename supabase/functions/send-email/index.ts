import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const FRONTEND_URL = Deno.env.get('FRONTEND_URL')!;
const RESEND_FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const WEBHOOK_KEY = Deno.env.get('WEBHOOK_KEY')!;

// ─── Shared layout wrapper ────────────────────────────────────────────────────

function layout(body: string): string {
  return `
<div style="font-family: ui-sans-serif, system-ui, sans-serif; max-width: 550px; margin: 0 auto; padding: 24px; background-color: #f9fafb;">
  <div style="background-color: #ffffff; padding: 24px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1);">
    ${body}
    <hr style="border: none; border-top: 1px solid #e5e7eb; margin: 20px 0 16px 0;">
    <p style="font-size: 12px; color: #9ca3af; margin: 0;">
      Bloomington Babysitting Co-op &mdash; <a href="${FRONTEND_URL}" style="color: #9ca3af;">BBC Clerk</a>
      <br>
      Log into your <a href="${FRONTEND_URL}/profile" style="color: #9ca3af;">profile</a> to update email notification preferences.
    </p>
  </div>
</div>`.trim();
}

function heading(text: string): string {
  return `<h1 style="font-size: 20px; font-weight: 700; margin: 0 0 12px 0; color: #111827;">${text}</h1>`;
}

function body(text: string): string {
  return `<p style="font-size: 15px; color: #374151; margin: 0 0 16px 0; line-height: 1.6;">${text}</p>`;
}

function btn(href: string, label: string): string {
  return `<a href="${href}" style="display: block; background-color: #1d4ed8; color: #ffffff; text-align: center; padding: 8px 16px; border-radius: 4px; text-decoration: none; font-size: 15px; font-weight: 500; margin-bottom: 16px;">${label}</a>`;
}

function muted(text: string): string {
  return `<p style="font-size: 13px; color: #6b7280; margin: 0; line-height: 1.5;">${text}</p>`;
}

function formatDate(d: string | null | undefined): string {
  if (!d) return '';
  try {
    const s = String(d).trim();
    const isoMatch = s.match(/^\d{4}-\d{2}-\d{2}/);
    const parsed = isoMatch ? new Date(isoMatch[0]) : new Date(s);
    if (Number.isNaN(parsed.getTime())) return s;
    return parsed.toLocaleDateString();
  } catch (_) {
    return String(d);
  }
}

function formatTime(t: string | null | undefined): string {
  if (!t) return 'TBD';
  const s = String(t).trim();
  const m = s.match(/^(\d{1,2}):(\d{2})/);
  if (!m) return s;
  const hhmm = `${m[1].padStart(2, '0')}:${m[2]}`;
  try {
    const parsed = new Date(`1970-01-01T${hhmm}:00`);
    if (Number.isNaN(parsed.getTime())) return hhmm;
    return parsed.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }).toLowerCase();
  } catch (_) {
    return hhmm;
  }
}

function formatHours(value: number): string {
  const sign = value >= 0 ? '+' : '';
  const color = value >= 0 ? '#16a34a' : '#dc2626';
  return `<strong style="color: ${color};">${sign}${value.toFixed(2)} hours</strong>`;
}

function formatChildAge(dob: unknown): string {
  if (!dob) return '';
  const s = String(dob).trim();
  const parts = s.split('-');
  const year = parseInt(parts[0], 10);
  if (Number.isNaN(year)) return s;
  const month = parts.length > 1 && parts[1] ? Math.max(0, Math.min(11, parseInt(parts[1], 10) - 1)) : 0;
  // calculate from the 15th of the month
  const dobDate = new Date(year, month, 15);
  if (isNaN(dobDate.getTime())) return s;

  const now = new Date();
  let years = now.getFullYear() - dobDate.getFullYear();
  let months = now.getMonth() - dobDate.getMonth();
  if (now.getDate() < dobDate.getDate()) months -= 1;
  if (months < 0) {
    years -= 1;
    months += 12;
  }

  if (years < 0) years = 0;
  if (months < 0) months = 0;

  return `${years}y ${months}m`;
}

function assignLabel(order: unknown, show: unknown): string {
  const labels = {
    1: 'Primary',
    2: 'Secondary',
    3: 'Tertiary'
  } as Record<number, string>;
  const label = labels[Number(order ?? 0)];
  if (!show || !label) return '';
  return ` as <strong>${label}</strong>`;
}

function requestViewUrl(requestId: unknown): string {
  return `${FRONTEND_URL}/request-view?id=${String(requestId)}`;
}

function requestListUrl(): string {
  return `${FRONTEND_URL}/requests`;
}

function ledgerUrl(): string {
  return `${FRONTEND_URL}/ledger`;
}

function entryUrl(): string {
  return `${FRONTEND_URL}/entry-new`;
}

function chunk<T>(items: T[], size: number): T[][] {
  const parts: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    parts.push(items.slice(i, i + size));
  }
  return parts;
}

function toHex(bytes: Uint8Array): string {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
}

async function sha256Hex(input: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return toHex(new Uint8Array(digest));
}

async function buildBatchIdempotencyKey(
  event: Record<string, unknown>,
  batch: Array<{ from: string; to: string[]; subject: string; html: string }>,
  batchIndex: number,
): Promise<string> {
  const type = String(event.type ?? 'unknown');
  const source = String(event.source ?? 'unknown');
  const queueId = typeof event.id === 'string' ? event.id : '';

  // Prefer a stable key tied to the queue row id when available.
  if (queueId) {
    return `${type}/${source}/${queueId}/batch-${batchIndex}`.slice(0, 256);
  }

  // Fallback for transports that don't include row ids.
  const digest = await sha256Hex(JSON.stringify({ type, source, batchIndex, batch }));
  return `${type}/${source}/hash-${digest}`.slice(0, 256);
}

function parseJsonString(value: unknown): unknown {
  if (typeof value !== 'string') return value;
  try {
    return JSON.parse(value);
  } catch (_) {
    return value;
  }
}

function normalizeWebhookBody(rawBody: unknown): unknown {
  let body = parseJsonString(rawBody);
  if (!body || typeof body !== 'object' || Array.isArray(body)) return body;

  const outer = body as Record<string, unknown>;

  // Some transports wrap JSON in a `body` string.
  if (typeof outer.body === 'string') {
    body = parseJsonString(outer.body);
  }

  if (!body || typeof body !== 'object' || Array.isArray(body)) return body;
  const normalized = body as Record<string, unknown>;

  // Accept direct queue-row payloads in addition to documented webhook envelopes.
  if (
    normalized.record === undefined
    && typeof normalized.type === 'string'
    && typeof normalized.source === 'string'
    && normalized.payload !== undefined
  ) {
    return {
      type: 'INSERT',
      table: 'email_queue',
      schema: 'public',
      record: normalized,
      old_record: null,
    };
  }

  return normalized;
}

function summarizeWebhookEvent(body: unknown): Record<string, unknown> {
  if (!body || typeof body !== 'object' || Array.isArray(body)) {
    return {
      bodyType: Array.isArray(body) ? 'array' : typeof body,
      recipientCount: 0,
    };
  }

  const event = body as Record<string, unknown>;
  const record = event.record && typeof event.record === 'object' && !Array.isArray(event.record)
    ? event.record as Record<string, unknown>
    : null;
  const parsedQueuePayload = record && typeof record.payload === 'string'
    ? parseJsonString(record.payload)
    : record?.payload;
  const payload = Array.isArray(parsedQueuePayload) ? parsedQueuePayload : [];

  let recipientCount = 0;
  let firstRecipient: Record<string, unknown> | null = null;
  for (const item of payload) {
    if (!item || typeof item !== 'object' || Array.isArray(item)) continue;
    const row = item as Record<string, unknown>;
    if (!firstRecipient) firstRecipient = row;
    recipientCount += collectRecipientEmails(row).length;
  }

  const firstMeta = firstRecipient?.meta && typeof firstRecipient.meta === 'object' && !Array.isArray(firstRecipient.meta)
    ? firstRecipient.meta as Record<string, unknown>
    : null;

  return {
    webhookType: typeof event.type === 'string' ? event.type : null,
    webhookTable: typeof event.table === 'string' ? event.table : null,
    webhookSchema: typeof event.schema === 'string' ? event.schema : null,
    queueId: typeof record?.id === 'string' ? record.id : null,
    queueType: typeof record?.type === 'string' ? record.type : null,
    queueSource: typeof record?.source === 'string' ? record.source : null,
    recipientCount,
    sampleRequestId: firstMeta?.request_id ?? null,
    sampleLedgerId: firstMeta?.ledger_id ?? null,
  };
}

function collectRecipientEmails(row: Record<string, unknown>): string[] {
  const recipients: string[] = [];

  const email = typeof row.email === 'string' ? row.email.trim() : '';
  if (email) recipients.push(email);

  if (Array.isArray(row.emails)) {
    for (const value of row.emails) {
      if (typeof value !== 'string') continue;
      const trimmed = value.trim();
      if (trimmed) recipients.push(trimmed);
    }
  }

  return Array.from(new Set(recipients));
}

// ─── Template map ─────────────────────────────────────────────────────────────

type Meta = Record<string, unknown> & { source: string };

const templates: Record<string, (meta: Meta) => { subject: string; html: string }> = {

  // End-of-month hours summary (1st of next month)
  email_endmonth_summary: (meta) => {
    const start = Number(meta.start_balance ?? 0);
    const end = Number(meta.end_balance ?? 0);
    return {
      subject: 'Your monthly hours summary',
      html: layout(`
        ${heading('Monthly summary')}
        ${body(`Here is your hours balance summary for last month:`)}
        <table style="width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 14px;">
          <tr>
            <td style="padding: 6px 8px; color: #6b7280; border-bottom: 1px solid #f3f4f6;">Opening balance</td>
            <td style="padding: 6px 8px; text-align: right; font-weight: 600; color: #111827; border-bottom: 1px solid #f3f4f6;">${formatHours(start)}</td>
          </tr>
          <tr>
            <td style="padding: 6px 8px; color: #6b7280; border-bottom: 1px solid #f3f4f6;">Month change</td>
            <td style="padding: 6px 8px; text-align: right; font-weight: 600; color: #111827; border-bottom: 1px solid #f3f4f6;">${formatHours(end - start)}</td>
          </tr>
          <tr>
            <td style="padding: 6px 8px; color: #6b7280;">Closing balance</td>
            <td style="padding: 6px 8px; text-align: right; font-weight: 600; color: #111827;">${formatHours(end)}</td>
          </tr>
        </table>
        ${btn(ledgerUrl(), 'View ledger')}
      `),
    };
  },

  // Mid-month inactive reminder (15th of month)
  email_midmonth_inactive: (_meta) => ({
    subject: 'Mid-month activity reminder',
    html: layout(`
      ${heading('No activity recorded yet this month')}
      ${body("You haven't participated in the co-op this month.")}
      ${btn(requestListUrl(), 'View available requests')}
      ${muted('Log in to offer help or create a new request in BBC Clerk.')}
    `),
  }),

  // Your hours balance changed
  email_ledger_change: (meta) => {
    const delta = Number(meta.hours_delta ?? 0);
    const balance = Number(meta.current_balance ?? 0);
    return {
      subject: 'Your hours balance has changed',
      html: layout(`
        ${heading('Hours balance updated')}
        ${body(`A ledger entry was recorded by <strong>${meta.author_email}</strong>: ${formatHours(delta)}`)}
        ${body(`Your current balance is: ${formatHours(balance)}`)}
        ${btn(ledgerUrl(), 'View ledger')}
        ${muted('Contact a co-op admin if you believe this entry is incorrect.')}
      `),
    };
  },

  // Another family's request has been created
  email_other_request_new: (meta) => {
    const req = (meta.request ?? {}) as Record<string, any>;
    const children = Array.isArray(meta.children) ? meta.children : [];
    const family = String(req.requester_family_name ?? '');
    const type = String(req.type ?? '').replace(/^./, (c) => c.toUpperCase());
    const notes = String(req.notes ?? '');
    const date = formatDate(req.date);
    const start = formatTime(req.start_time);
    const end = formatTime(req.end_time);
    const date_flex = !!req.flexible_date && req.date ? ' (flex)' : '';
    const time_flex = (!!req.flexible_start_time || !!req.flexible_end_time) && (req.start_time || req.end_time) ? ' (flex)' : '';
    const hours = req.hours != null ? Number(req.hours) : null;
    let sit_location = String(req.sit_location ?? '').trim();
    switch (sit_location) {
      case 'requester_house':
        sit_location = "Requester's House";
        break;
      case 'sitter_house':
        sit_location = "Sitter's House";
        break;
      case 'either':
        sit_location = 'Either';
        break;
    }
    const meal_required = !!req.meal_required;
    const meal_prepared_by_sitter = !!req.meal_prepared_by_sitter;
    const sitters_children_welcome = !!req.sitters_children_welcome;
    const pets_are_present = !!req.pets_are_present;
    const origin = req.origin || '';
    const destination = req.destination || '';
    const adult_count = req.adult_count || 0;

    const typeSpecificHtml = (type.toLowerCase() === 'babysit') ? `
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Sit location</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${sit_location}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Meal required</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${meal_required ? 'Yes' : 'No'}</td>
      </tr>
      ${meal_required ? `
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Meal prepared by sitter</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${meal_prepared_by_sitter ? 'Yes' : 'No'}</td>
      </tr>
      ` : ''}
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Sitter's children welcome</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${sitters_children_welcome ? 'Yes' : 'No'}</td>
      </tr>
      ${sitters_children_welcome ? `
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Pets are present</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${pets_are_present ? 'Yes' : 'No'}</td>
      </tr>
      ` : ''}
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6; vertical-align:top;">Children</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6; vertical-align:top;">
          ${children.length > 0 ? children.map((c: any) => `
            <div style="text-align: left; margin-bottom:8px; border-bottom:1px solid #f3f4f6;">
              <div>${c.name} (${formatChildAge(c.date_of_birth)})</div>
              ${c.allergies ? `<div style="font-weight:600;">Allergies: ${c.allergies}</div>` : ''}
              ${c.notes ? `<div style="font-style: italic;">Notes: ${c.notes}</div>` : ''} 
            </div>
          `).join('') : 'No children selected'}
        </td>
      </tr>
    ` : ((type.toLowerCase() === 'drive') ? `
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Origin</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${origin}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Destination</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${destination}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Adults</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${adult_count}</td>
      </tr>
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6; vertical-align:top;">Children</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6; vertical-align:top;">
          ${children.length > 0 ? children.map((c: any) => `
            <div style="text-align: left; margin-bottom:8px; border-bottom:1px solid #f3f4f6;">
              <div>${c.name} (${formatChildAge(c.date_of_birth)})</div>
              ${c.car_seat ? `<div style="font-weight:600;">Car seat: ${c.car_seat}</div>` : ''}
            </div>
          `).join('') : 'No children selected'}
        </td>
      </tr>
    ` : '');

    const hoursRow = (hours !== null && !Number.isNaN(hours)) ? `
      <tr>
        <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Hours</td>
        <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${hours}</td>
      </tr>
    ` : '';

    const detailsTable = `
      <table style="width:100%; border-collapse:collapse; margin-bottom:16px; font-size:14px;">
        <tr>
          <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Type</td>
          <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${type}</td>
        </tr>
        <tr>
          <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Description</td>
          <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${notes}</td>
        </tr>
        <tr>
          <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Date</td>
          <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${date}${date_flex}</td>
        </tr>
        <tr>
          <td style="padding:6px 8px; color:#6b7280; border-bottom:1px solid #f3f4f6;">Time</td>
          <td style="padding:6px 8px; text-align: left; color:#111827; border-bottom:1px solid #f3f4f6;">${start}${type.toLowerCase() === 'drive' ? '' : ' - ' + end}${time_flex}</td>
        </tr>
        ${hoursRow}
        ${typeSpecificHtml}
      </table>
    `;

    return {
      subject: `New ${type} request from the ${family} family`,
      html: layout(`
        ${heading('New request available')}
        ${body(`The <strong>${family}</strong> family has posted a new request.`)}
        ${detailsTable}
        ${btn(requestViewUrl(req.id || meta.request_id || ''), 'View request')}
        ${muted('Log in to view current details and submit an offer.')}
      `),
    };
  },

  // Another family's request has been open for 3 days with no offer
  email_other_request_unoffered: (meta) => ({
    subject: `${meta.requester_family_name}'s request has no offers yet`,
    html: layout(`
      ${heading('No offers yet')}
      ${body(`${meta.requester_family_name}'s upcoming request has been open for 3 days without receiving any offers.`)}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('Consider offering your help.')}
    `),
  }),

  // Another family's request will expire in 2 days
  email_other_request_expiring: (meta) => ({
    subject: `${meta.requester_family_name}'s request will expire in 2 days`,
    html: layout(`
      ${heading('Request expiring soon')}
      ${body(`${meta.requester_family_name}'s upcoming request still needs coverage and is 2 days away.`)}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('Consider offering your help.')}
    `),
  }),

  // Your family's request has an offer to help
  email_my_request_offered: (meta) => {
    const action = ({
      rpc_create_offer: 'submitted',
      rpc_update_offer: 'updated',
      rpc_cancel_offer: 'cancelled'
    } as Record<string,string>)[meta.source] ?? 'changed';
    return {
      subject: `Your request has a ${action} offer`,
      html: layout(`
        ${heading('Someone offered to help')}
        ${body(`The <strong>${meta.offer_family_name}</strong> family has ${action} an offer to help on your request.`)}
        ${btn(requestViewUrl(meta.request_id), 'View request')}
        ${muted('Log in to review offers and assign a helper.')}
      `),
    };
  },

  // Your family's request has been open for 3 days with no offer
  email_my_request_unoffered: (meta) => ({
    subject: 'Your request has no offers yet',
    html: layout(`
      ${heading('No offers yet')}
      ${body('Your upcoming request has been open for 3 days without receiving any offers.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('Consider reaching out to co-op members directly if you need coverage.')}
    `),
  }),

  // Your family's request will expire in 2 days
  email_my_request_expiring: (meta) => ({
    subject: 'Your request will expire in 2 days',
    html: layout(`
      ${heading('Request expiring soon')}
      ${body('Your upcoming request still needs coverage and is 2 days away.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('Consider reaching out to co-op members directly if you need coverage.')}
    `),
  }),

  // Your family's request has expired
  email_my_request_expired: (meta) => ({
    subject: 'Your request expired without being assigned',
    html: layout(`
      ${heading('Request expired')}
      ${body('Your request date passed without being assigned to a helper.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('You can submit a new request if you still need help.')}
    `),
  }),

  // Your offer was assigned / unassigned / reassigned to a different priority
  email_my_offer_assigned: (meta) => {
    return {
      subject: `Your offer to help has been ${meta.action}`,
      html: layout(`
        ${heading('Your offer status changed')}
        ${body(`Your offer to help on a request by the <strong>${meta.requester_family_name}</strong> family has been ${meta.action}${assignLabel(meta.assign_order, meta.show_assign_order)}.`)}
        ${meta.action === 'unassigned'
          ? ''
          : Number(meta.assign_order) === 1
            ? body('You are now expected to complete the request.')
            : body('You may be asked to complete the request if the primary becomes unavailable.')
        }
        ${btn(requestViewUrl(meta.request_id), 'View request')}
        ${muted('Log in to view details.')}
      `),
    };
  },

  // A request you offered on was updated or cancelled
  email_my_offer_change: (meta) => {
    const action = ({
      rpc_update_request: 'updated',
      rpc_cancel_request: 'cancelled'
    } as Record<string,string>)[meta.source] ?? 'updated or cancelled';
    return {
      subject: 'A request you offered to help with has changed',
      html: layout(`
        ${heading('Request updated')}
        ${body(`A request by the <strong>${meta.requester_family_name}</strong> family that you offer to help with has been ${action}.`)}
        ${btn(requestViewUrl(meta.request_id), 'View request')}
        ${muted('Log in to review the current state of the request.')}
      `),
    };
  },

  // A request you were assigned to has been completed
  email_my_offer_completed: (meta) => ({
    subject: 'Request marked as completed',
    html: layout(`
      ${heading('Request completed')}
      ${body(`You were assigned${assignLabel(meta.assign_order, meta.show_assign_order)} to a request by the <strong>${meta.requester_family_name}</strong> family that has been marked as completed.`)}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${Number(meta.assign_order) === 1
        ? `${btn(entryUrl(), 'Submit ledger entry')}
      ${muted('Log in to create a ledger entry and record the hours.')}`
        : muted('A ledger entry has been automatically recorded for your retainer hours.')}
    `),
  })
};

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request) => {
  const webhookKeyHeader = req.headers.get('x-supabase-webhook-source') || '';
  if (!WEBHOOK_KEY || webhookKeyHeader !== WEBHOOK_KEY) {
    console.warn('send-email: unauthorized webhook request');
    return new Response('Unauthorized', { status: 401 });
  }

  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch (err) {
    console.error('send-email: invalid JSON request body', err);
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const eventBody = normalizeWebhookBody(rawBody);

  // Keep logs useful for troubleshooting without printing recipient email/meta payloads.
  console.log('send-email received summary:', JSON.stringify(summarizeWebhookEvent(eventBody)));

  if (!eventBody || typeof eventBody !== 'object') {
    return new Response(JSON.stringify({ error: 'Invalid payload. Expected an object body.' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const webhookEvent = eventBody as Record<string, unknown>;
  if (
    typeof webhookEvent.type !== 'string'
    || typeof webhookEvent.table !== 'string'
    || typeof webhookEvent.schema !== 'string'
    || !webhookEvent.record
    || typeof webhookEvent.record !== 'object'
    || Array.isArray(webhookEvent.record)
  ) {
    return new Response(JSON.stringify({
      error: 'Invalid payload. Expected Supabase webhook shape { type, table, schema, record, old_record }',
    }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const queueEvent = webhookEvent.record as Record<string, unknown>;
  if (typeof queueEvent.payload === 'string') {
    queueEvent.payload = parseJsonString(queueEvent.payload);
  }

  if (!queueEvent.type || !queueEvent.source || !Array.isArray(queueEvent.payload)) {
    return new Response(JSON.stringify({
      error: 'Invalid webhook record. Expected record.{ type, source, payload: recipient[] }',
    }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const type = String(queueEvent.type);
  const source = String(queueEvent.source);
  const recipients = queueEvent.payload as unknown[];
  const template = templates[type];

  if (!template) {
    return new Response(JSON.stringify({ error: `Unknown email type: ${type}` }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const emails: Array<{ from: string; to: string[]; subject: string; html: string }> = [];
  let recipientCount = 0;
  for (let i = 0; i < recipients.length; i += 1) {
    const recipient = recipients[i];
    if (!recipient || typeof recipient !== 'object' || Array.isArray(recipient)) {
      return new Response(JSON.stringify({ error: `Invalid recipient at index ${i}: expected object` }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const row = recipient as Record<string, unknown>;
    const recipientEmails = collectRecipientEmails(row);
    if (recipientEmails.length === 0) {
      return new Response(JSON.stringify({ error: `Invalid recipient at index ${i}: missing email(s)` }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const rowMeta = row.meta;
    const metaObj = rowMeta && typeof rowMeta === 'object' && !Array.isArray(rowMeta)
      ? rowMeta as Record<string, unknown>
      : {};

    const mergedMeta: Meta = { ...metaObj, source };
    const rendered = template(mergedMeta);

    // Resend supports up to 50 recipients in the to[] list for a single message.
    const recipientGroups = chunk(recipientEmails, 1);
    for (const toList of recipientGroups) {
      emails.push({
        from: RESEND_FROM_EMAIL,
        to: toList,
        subject: rendered.subject,
        html: rendered.html,
      });
      recipientCount += toList.length;
    }
  }

  if (emails.length === 0) {
    return new Response(JSON.stringify({ data: [], count: 0, messages: 0, batches: 0 }), {
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const batches = chunk(emails, 100);
  const sent: unknown[] = [];

  for (let batchIndex = 0; batchIndex < batches.length; batchIndex += 1) {
    const batch = batches[batchIndex];
    const idempotencyKey = await buildBatchIdempotencyKey(queueEvent, batch, batchIndex);

    const res = await fetch('https://api.resend.com/emails/batch', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${RESEND_API_KEY}`,
        'Idempotency-Key': idempotencyKey,
      },
      body: JSON.stringify(batch),
    });

    const raw = await res.text();
    let data: unknown = null;
    if (raw) {
      try {
        data = JSON.parse(raw);
      } catch (_err) {
        data = { raw };
      }
    }

    if (!res.ok) {
      return new Response(JSON.stringify({
        error: 'Resend batch send failed',
        status: res.status,
        details: data,
      }), {
        status: 502,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    if (data && typeof data === 'object' && Array.isArray((data as Record<string, unknown>).data)) {
      sent.push(...((data as Record<string, unknown>).data as unknown[]));
    } else if (data !== null) {
      sent.push(data);
    }
  }

  return new Response(JSON.stringify({
    data: sent,
    count: recipientCount,
    messages: emails.length,
    batches: batches.length,
  }), {
    headers: { 'Content-Type': 'application/json' },
  });
});
