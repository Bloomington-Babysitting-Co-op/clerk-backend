import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY')!;
const RESEND_FROM_EMAIL = Deno.env.get('RESEND_FROM_EMAIL')!;
const FRONTEND_URL = Deno.env.get('FRONTEND_URL')!;

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

function requestUrl(requestId: string): string {
  return `${FRONTEND_URL}/request-view?id=${requestId}`;
}

function ledgerUrl(): string {
  return `${FRONTEND_URL}/ledger`;
}

function profileUrl(): string {
  return `${FRONTEND_URL}/profile`;
}

// ─── Template map ─────────────────────────────────────────────────────────────

type Meta = Record<string, unknown>;

const templates: Record<string, (meta: Meta) => { subject: string; html: string }> = {

  // Someone offered to help with your request
  email_request_offered: (meta) => ({
    subject: 'New offer on your request',
    html: layout(`
      ${heading('Someone offered to help')}
      ${body(`<strong>${meta.offer_family_name ?? 'A family'}</strong> has submitted an offer on your request.`)}
      ${btn(requestUrl(meta.request_id as string), 'View request')}
      ${muted('Log in to review offers and assign a helper.')}
    `),
  }),

  // Your request was never assigned and is approaching expiry (2 days out)
  email_request_unoffered: (meta) => ({
    subject: 'Your request has no offers yet',
    html: layout(`
      ${heading('No offers yet')}
      ${body('Your upcoming request has not received any offers and is 2 days away.')}
      ${btn(requestUrl(meta.request_id as string), 'View request')}
      ${muted('Consider reaching out to co-op members directly if you need coverage.')}
    `),
  }),

  // Your request expired without being assigned
  email_request_expired: (meta) => ({
    subject: 'Your request expired without being assigned',
    html: layout(`
      ${heading('Request expired')}
      ${body('Your request passed without being assigned to a helper.')}
      ${btn(requestUrl(meta.request_id as string), 'View request')}
      ${muted('You can submit a new request if you still need help.')}
    `),
  }),

  // A new request was posted by any other family
  email_request_new: (meta) => ({
    subject: 'New request posted',
    html: layout(`
      ${heading('New request available')}
      ${body('A family has posted a new request. Log in to view details and submit an offer.')}
      ${btn(requestUrl(meta.request_id as string), 'View request')}
      ${muted('You are receiving this because you opted into new request notifications.')}
    `),
  }),

  // Your offer was accepted / unassigned (offer_assigned covers both directions)
  email_offer_assigned: (meta) => ({
    subject: 'Update on your offer',
    html: layout(`
      ${heading('Your offer status changed')}
      ${body('Your offer on a co-op request has been updated. Log in to see the current assignment status.')}
      ${btn(requestUrl(meta.request_id as string), 'View request')}
      ${muted('Contact the requesting family if you have questions.')}
    `),
  }),

  // A sit you were assigned to has been completed
  email_offer_completed: (meta) => ({
    subject: 'Sit marked as completed',
    html: layout(`
      ${heading('Sit completed')}
      ${body('A request you were assigned to has been marked as completed. You may now select it to submit a ledger entry.')}
      ${btn(requestUrl(meta.request_id as string), 'View request')}
      ${btn(ledgerUrl(), 'Submit ledger entry')}
      ${muted('A ledger entry should be created to record the hours.')}
    `),
  }),

  // A request you offered on was updated or cancelled
  email_offer_change: (meta) => ({
    subject: 'A request you offered on has changed',
    html: layout(`
      ${heading('Request updated')}
      ${body('A request you submitted an offer on has been updated or cancelled.')}
      ${btn(requestUrl(meta.request_id as string), 'View request')}
      ${muted('Log in to review the current state of the request.')}
    `),
  }),

  // Your hours balance changed
  email_ledger_change: (meta) => {
    const delta = Number(meta.hours_delta ?? 0);
    const balance = Number(meta.current_balance ?? 0);
    const sign = delta >= 0 ? '+' : '';
    return {
      subject: 'Your hours balance changed',
      html: layout(`
        ${heading('Hours balance updated')}
        ${body(`A ledger entry was recorded: <strong>${sign}${delta.toFixed(2)} hrs</strong>. Your current balance is <strong>${balance.toFixed(2)} hrs</strong>.`)}
        ${btn(ledgerUrl(), 'View ledger')}
        ${muted('Contact a co-op admin if you believe this entry is incorrect.')}
      `),
    };
  },

  // Mid-month inactive reminder (15th of month)
  email_midmonth_inactive: (_meta) => ({
    subject: 'Mid-month activity reminder',
    html: layout(`
      ${heading('No activity recorded yet this month')}
      ${body("You haven't participated in the co-op this month. Active participation keeps the co-op healthy.")}
      ${btn(`${FRONTEND_URL}/`, 'View available requests')}
      ${muted('You can offer to help on any future request in BBC Clerk.')}
    `),
  }),

  // End-of-month hours summary (1st of next month)
  email_endmonth_summary: (meta) => {
    const start = Number(meta.start_balance ?? 0);
    const end = Number(meta.end_balance ?? 0);
    const delta = end - start;
    const sign = delta >= 0 ? '+' : '';
    return {
      subject: 'Your monthly hours summary',
      html: layout(`
        ${heading('Monthly summary')}
        ${body(`Here is your hours balance summary for last month:`)}
        <table style="width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 14px;">
          <tr>
            <td style="padding: 6px 8px; color: #6b7280; border-bottom: 1px solid #f3f4f6;">Opening balance</td>
            <td style="padding: 6px 8px; text-align: right; font-weight: 600; color: #111827; border-bottom: 1px solid #f3f4f6;">${start.toFixed(2)} hrs</td>
          </tr>
          <tr>
            <td style="padding: 6px 8px; color: #6b7280; border-bottom: 1px solid #f3f4f6;">Month change</td>
            <td style="padding: 6px 8px; text-align: right; font-weight: 600; color: #111827; border-bottom: 1px solid #f3f4f6;">${sign}${delta.toFixed(2)} hrs</td>
          </tr>
          <tr>
            <td style="padding: 6px 8px; color: #6b7280;">Closing balance</td>
            <td style="padding: 6px 8px; text-align: right; font-weight: 600; color: #111827;">${end.toFixed(2)} hrs</td>
          </tr>
        </table>
        ${btn(ledgerUrl(), 'View ledger')}
      `),
    };
  },
};

// ─── Handler ──────────────────────────────────────────────────────────────────

Deno.serve(async (req) => {
  const payload = await req.json();

  // Accepts either a direct {to, subject, html} call (existing usage)
  // or a pg_notify payload {email, type, meta}
  let to: string;
  let subject: string;
  let html: string;

  if (payload.type && payload.email) {
    // Called from pg_notify via realtime/webhook
    const { email, type, meta = {} } = payload;
    const template = templates[type];
    if (!template) {
      return new Response(JSON.stringify({ error: `Unknown email type: ${type}` }), {
        status: 400,
        headers: { 'Content-Type': 'application/json' },
      });
    }
    const rendered = template(meta as Meta);
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
