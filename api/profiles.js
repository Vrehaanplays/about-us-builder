import { put, list } from '@vercel/blob';

const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const allowedImageTypes = new Set(['image/jpeg', 'image/png', 'image/webp']);
const clean = (value, limit = 250) => String(value || '').trim().slice(0, limit);
const isAdmin = (request) => {
  const password = request.headers.get('x-admin-password');
  return Boolean(process.env.ADMIN_PASSWORD) && password === process.env.ADMIN_PASSWORD;
};
const recordPath = (id) => `profile-roster/records/${id}.json`;

async function readRecords() {
  const { blobs } = await list({ prefix: 'profile-roster/records/' });
  const records = await Promise.all(blobs.map(async ({ url }) => {
    const response = await fetch(url, { cache: 'no-store' });
    return response.ok ? response.json() : null;
  }));
  return records.filter(Boolean).sort((a, b) => new Date(b.createdAt) - new Date(a.createdAt));
}

export default async function handler(request) {
  try {
    if (request.method === 'POST') {
      const data = await request.formData();
      const name = clean(data.get('name'), 80);
      const role = clean(data.get('role'), 100);
      const school = clean(data.get('school'), 120);
      const grade = clean(data.get('grade'), 40);
      const bio = clean(data.get('bio'), 400);
      const showBio = data.get('showBio') === 'true';
      const photo = data.get('photo');
      if (!name || !role || !school || !grade || !(photo instanceof File)) {
        return Response.json({ error: 'Please complete every required field and include an image.' }, { status: 400 });
      }
      if (!allowedImageTypes.has(photo.type) || photo.size > MAX_IMAGE_BYTES) {
        return Response.json({ error: 'Use a JPG, PNG, or WebP image smaller than 5 MB.' }, { status: 400 });
      }
      const id = crypto.randomUUID();
      const extension = photo.type.split('/')[1].replace('jpeg', 'jpg');
      const image = await put(`profile-roster/images/${id}.${extension}`, photo, { access: 'public', addRandomSuffix: false, contentType: photo.type });
      const profile = { id, name, role, school, grade, bio, showBio, imageUrl: image.url, status: 'pending', rejectionReason: '', createdAt: new Date().toISOString(), reviewedAt: null };
      await put(recordPath(id), JSON.stringify(profile), { access: 'public', addRandomSuffix: false, allowOverwrite: true, contentType: 'application/json; charset=utf-8' });
      return Response.json({ ok: true, id }, { status: 201 });
    }

    if (request.method === 'GET') {
      const status = new URL(request.url).searchParams.get('status') || 'accepted';
      const admin = isAdmin(request);
      if (status !== 'accepted' && !admin) return Response.json({ error: 'Unauthorized' }, { status: 401 });
      const records = await readRecords();
      return Response.json({ profiles: records.filter((profile) => profile.status === status) });
    }

    if (request.method === 'PATCH') {
      if (!isAdmin(request)) return Response.json({ error: 'Unauthorized' }, { status: 401 });
      const { id, status, rejectionReason = '' } = await request.json();
      if (!id || !['accepted', 'rejected'].includes(status)) return Response.json({ error: 'Invalid review request.' }, { status: 400 });
      if (status === 'rejected' && !clean(rejectionReason, 300)) return Response.json({ error: 'A rejection reason is required.' }, { status: 400 });
      const records = await readRecords();
      const profile = records.find((item) => item.id === id);
      if (!profile) return Response.json({ error: 'Profile not found.' }, { status: 404 });
      profile.status = status;
      profile.rejectionReason = status === 'rejected' ? clean(rejectionReason, 300) : '';
      profile.reviewedAt = new Date().toISOString();
      await put(recordPath(id), JSON.stringify(profile), { access: 'public', addRandomSuffix: false, allowOverwrite: true, contentType: 'application/json; charset=utf-8' });
      return Response.json({ ok: true, profile });
    }

    return new Response('Method Not Allowed', { status: 405, headers: { Allow: 'GET, POST, PATCH' } });
  } catch (error) {
    console.error(error);
    return Response.json({ error: 'Storage is not configured or the request could not be completed.' }, { status: 500 });
  }
}
