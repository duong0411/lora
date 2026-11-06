/**
 * SATLO FCM Bridge
 * Nghe MQTT tele/{CHIP}_alarm/status → gửi FCM topic satlo_{CHIP}
 *
 * Env:
 *   MQTT_URL=wss://mqtt.duynguyen.io.vn/mqtt
 *   GOOGLE_APPLICATION_CREDENTIALS=/path/serviceAccount.json
 *   (hoặc FIREBASE_SERVICE_ACCOUNT_JSON='{...}')
 */

const mqtt = require('mqtt');
const admin = require('firebase-admin');

const MQTT_URL = process.env.MQTT_URL || 'wss://mqtt.duynguyen.io.vn/mqtt';
const ALARM_RE = /^tele\/(.+)_alarm\/status$/;

function initFirebase() {
  if (admin.apps.length) return;
  const raw = process.env.FIREBASE_SERVICE_ACCOUNT_JSON;
  if (raw) {
    const cred = JSON.parse(raw);
    admin.initializeApp({ credential: admin.credential.cert(cred) });
    console.log('[FCM] init from FIREBASE_SERVICE_ACCOUNT_JSON');
    return;
  }
  admin.initializeApp({ credential: admin.credential.applicationDefault() });
  console.log('[FCM] init from applicationDefault()');
}

function titleFor(type) {
  switch (String(type || '').toUpperCase()) {
    case 'WET_RISK':
      return '⚠️ Cảnh báo nguy cơ lũ!';
    case 'SAT_LO':
      return '🚨 Cảnh báo sạt lở!';
    case 'IMPACT':
      return '⚠️ Cảnh báo rung lắc';
    case 'TILT':
      return '⚠️ Cảnh báo nghiêng';
    default:
      return '⚠️ Cảnh báo SATLO';
  }
}

function bodyFor(type, j) {
  const metrics =
    j.water != null || j.soil != null
      ? ` · Mưa ${j.water ?? '--'}% · Đất ${j.soil ?? '--'}%`
      : '';
  switch (String(type || '').toUpperCase()) {
    case 'WET_RISK':
      return `Lượng mưa và độ ẩm đất cao — nguy cơ ngập/lũ.${metrics}`;
    case 'SAT_LO':
      return `Rung/nghiêng + ẩm cao — kiểm tra ngay.${metrics}`;
    case 'IMPACT':
      return 'IMU phát hiện va đập / rung mạnh.';
    case 'TILT':
      return 'Góc nghiêng vượt ngưỡng an toàn.';
    default:
      return `Gateway đang báo động.${metrics}`;
  }
}

async function sendFcm(chip, type, title, body) {
  const topic = `satlo_${chip}`.replace(/[^a-zA-Z0-9\-_.~%]/g, '_');
  const res = await admin.messaging().send({
    topic,
    notification: { title, body },
    data: {
      type: String(type || 'ALERT'),
      chip: String(chip),
      click_action: 'FLUTTER_NOTIFICATION_CLICK',
    },
    android: {
      priority: 'high',
      notification: {
        channelId: 'satlo_fcm_v1',
        sound: 'default',
        defaultVibrateTimings: true,
      },
    },
    apns: {
      payload: {
        aps: {
          sound: 'default',
          badge: 1,
          'interruption-level': 'time-sensitive',
        },
      },
    },
  });
  console.log(`[FCM] OK topic=${topic} id=${res}`);
}

function parseAlarm(payload) {
  try {
    const j = JSON.parse(payload);
    const value = String(j.value || '').toUpperCase();
    if (value !== 'ON') return null;
    const type = j.type || 'ALERT';
    return {
      type,
      title: (j.title && String(j.title).trim()) || titleFor(type),
      body: (j.body && String(j.body).trim()) || bodyFor(type, j),
    };
  } catch {
    return {
      type: 'ALERT',
      title: '⚠️ Cảnh báo SATLO',
      body: String(payload).slice(0, 180),
    };
  }
}

async function main() {
  initFirebase();

  console.log(`[MQTT] connect ${MQTT_URL}`);
  const client = mqtt.connect(MQTT_URL, {
    protocolVersion: 4,
    reconnectPeriod: 3000,
    connectTimeout: 15000,
  });

  client.on('connect', () => {
    console.log('[MQTT] connected — subscribe tele/+_alarm/status');
    client.subscribe('tele/+_alarm/status', { qos: 1 });
  });

  client.on('message', async (topic, buf) => {
    const m = topic.match(ALARM_RE);
    if (!m) return;
    const chip = m[1];
    const parsed = parseAlarm(buf.toString('utf8'));
    if (!parsed) {
      console.log(`[MQTT] ${chip} alarm OFF/ignore`);
      return;
    }
    console.log(`[MQTT] ALARM chip=${chip} type=${parsed.type}`);
    try {
      await sendFcm(chip, parsed.type, parsed.title, parsed.body);
    } catch (e) {
      console.error('[FCM] send fail', e.message || e);
    }
  });

  client.on('error', (e) => console.error('[MQTT] error', e.message || e));
  client.on('reconnect', () => console.log('[MQTT] reconnecting...'));
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
