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

  // A new request was posted by any other family
/*
  email_request_new: (meta) => ({
    subject: 'New request posted',
    html: layout(`
      ${heading('New request available')}
      ${body(`The <strong>${meta.requester_family_name}</strong> family has posted a new request.`)}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('Log in to view details and submit an offer.')}
    `),
  }),
*/
  email_request_new: (meta) => {
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
    const origin = req.origin || '';
    const destination = req.destination || '';

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

  // Someone offered to help with your request
  email_request_offered: (meta) => {
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

  // Your request was never assigned and is approaching expiry (2 days out)
  email_request_unoffered: (meta) => ({
    subject: 'Your request has no offers yet',
    html: layout(`
      ${heading('No offers yet')}
      ${body('Your upcoming request has not received any offers and is 2 days away.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('Consider reaching out to co-op members directly if you need coverage.')}
    `),
  }),

  // Your request expired without being assigned
  email_request_expired: (meta) => ({
    subject: 'Your request expired without being assigned',
    html: layout(`
      ${heading('Request expired')}
      ${body('Your request date passed without being assigned to a helper.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('You can submit a new request if you still need help.')}
    `),
  }),

  // Your offer was assigned / unassigned
  email_offer_assigned: (meta) => {
    const action = ({
      rpc_assign_request: 'assigned',
      rpc_unassign_request: 'unassigned'
    } as Record<string,string>)[meta.source] ?? 'changed';
    return {
      subject: `Your offer to help has been ${action}`,
      html: layout(`
        ${heading('Your offer status changed')}
        ${body(`Your offer to help on a request by the <strong>${meta.requester_family_name}</strong> family has been ${action}.`)}
        ${btn(requestViewUrl(meta.request_id), 'View request')}
        ${muted('Log in to view details.')}
      `),
    };
  },

  // A request you were assigned to has been completed
  email_offer_completed: (meta) => ({
    subject: 'Request marked as completed',
    html: layout(`
      ${heading('Request completed')}
      ${body(`A request by the <strong>${meta.requester_family_name}</strong> family that you were assigned to has been marked as completed.`)}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${btn(entryUrl(), 'Submit ledger entry')}
      ${muted('Log in to create a ledger entry and record the hours.')}
    `),
  }),

  // A request you offered on was updated or cancelled
  email_offer_change: (meta) => {
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
};

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const webhookKeyHeader = req.headers.get('x-supabase-webhook-source') || '';
  if (!WEBHOOK_KEY || webhookKeyHeader !== WEBHOOK_KEY) {
    console.warn('send-email: unauthorized webhook request');
    return new Response('Unauthorized', { status: 401 });
  }

  let payload = await req.json();

  // Normalize/unpack common webhook shapes so they still arrive as the expected { email, type, source, meta } payload.
  try {
    if (payload && typeof payload === 'object') {
      if (typeof payload.payload === 'string') {
        try { payload = JSON.parse(payload.payload); } catch (_) { }
      } else if (payload.record && (payload.record.email || payload.record.type || payload.record.source)) {
        payload = payload.record;
      } else if (payload.body && typeof payload.body === 'string') {
        try { payload = JSON.parse(payload.body); } catch (_) { }
      }
    }
  } catch (err) {
    console.error('send-email: failed to normalize payload', err);
  }

  // Helpful debug log to inspect incoming shapes when troubleshooting
  console.log('send-email received payload:', JSON.stringify(payload));

  // Accepts either a direct {to, subject, html} call (existing usage)
  // or a webhook trigger payload {email, type, source, meta}
  let to: string;
  let subject: string;
  let html: string;

  if (payload.email && payload.type && payload.source) {
    // Called from webhook trigger on public.email_queue
    const { email, type, source, meta = {} } = payload;
    const template = templates[type];
    if (!template) {
      return new Response(JSON.stringify({ error: `Unknown email type: ${type}` }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    // Merge `source` into the meta object so templates can reference it
    const mergedMeta: Meta = { ...(meta ?? {}), source };
    const rendered = template(mergedMeta);
    to = email;
    subject = rendered.subject;
    html = rendered.html;
  } else {
    // Direct call with pre-built content
    to = payload.to;
    subject = payload.subject;
    html = payload.html;
  }

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${RESEND_API_KEY}`,
    },
    body: JSON.stringify({
      from: RESEND_FROM_EMAIL,
      to,
      subject,
      html,
    }),
  });

  const data = await res.json();
  return new Response(JSON.stringify(data), {
    headers: { 'Content-Type': 'application/json' },
  });
});
