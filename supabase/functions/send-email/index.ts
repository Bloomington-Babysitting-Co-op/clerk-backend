import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const FRONTEND_URL = Deno.env.get('FRONTEND_URL')!;
const RESEND_FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL')!;
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const WEBHOOK_KEY = Deno.env.get('WEBHOOK_KEY')!;

// ─── Shared layout wrapper ────────────────────────────────────────────────────

function layout(body: string): string {
  return `
<div style="font-family: ui-sans-serif, system-ui, sans-serif; max-width: 448px; margin: 0 auto; padding: 24px; background-color: #f9fafb;">
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

function muted(text: string): string {
  return `<p style="font-size: 13px; color: #6b7280; margin: 0; line-height: 1.5;">${text}</p>`;
}

function btn(href: string, label: string): string {
  return `<a href="${href}" style="display: block; background-color: #1d4ed8; color: #ffffff; text-align: center; padding: 8px 16px; border-radius: 4px; text-decoration: none; font-size: 15px; font-weight: 500; margin-bottom: 16px;">${label}</a>`;
}

function formatHours(value: number): string {
  const sign = value >= 0 ? '+' : '';
  const color = value >= 0 ? '#16a34a' : '#dc2626';
  return `<strong style="color: ${color};">${sign}${value.toFixed(2)} hours</strong>`;
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
        ${body(`A ledger entry was recorded: ${formatHours(delta)}.`)}
        ${body(`Your current balance is: ${formatHours(balance)}.`)}
        ${btn(ledgerUrl(), 'View ledger')}
        ${muted('Contact a co-op admin if you believe this entry is incorrect.')}
      `),
    };
  },

  // A new request was posted by any other family
  email_request_new: (meta) => ({
    subject: 'New request posted',
    html: layout(`
      ${heading('New request available')}
      ${body('A family has posted a new request.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('Log in to view details and submit an offer.')}
    `),
  }),

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
        ${body(`<strong>${meta.offer_family_name ?? 'A family'}</strong> has ${action} an offer on your request.`)}
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
      ${body('Your request passed without being assigned to a helper.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${muted('You can submit a new request if you still need help.')}
    `),
  }),

  // Your offer was accepted / unassigned (offer_assigned covers both directions)
  email_offer_assigned: (meta) => {
    const action = ({
      rpc_assign_request: 'assigned',
      rpc_unassign_request: 'unassigned'
    } as Record<string,string>)[meta.source] ?? 'changed';
    return {
      subject: `Your offer has been ${action}`,
      html: layout(`
        ${heading('Your offer status changed')}
        ${body(`Your offer on a request has been ${action}.`)}
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
      ${body('A request you were assigned to has been marked as completed.')}
      ${btn(requestViewUrl(meta.request_id), 'View request')}
      ${btn(ledgerUrl(), 'Submit ledger entry')}
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
      subject: 'A request you offered on has changed',
      html: layout(`
        ${heading('Request updated')}
        ${body(`A request you submitted an offer on has been ${action}.`)}
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
