const $ = (id) => document.getElementById(id);
const inputs = ['name','role','school','grade','bio'].map($);
const photoInput = $('photo-input');
let photoUrl = '';

function initials(value) {
  return value.trim().split(/\s+/).filter(Boolean).slice(0, 2).map(word => word[0]).join('').toUpperCase() || 'ME';
}
function setText(id, value, fallback) { $(id).textContent = value.trim() || fallback; }
function updateCard() {
  const name = $('name').value;
  setText('card-name', name, 'Your name');
  setText('card-role', $('role').value, 'Your role');
  setText('card-school', $('school').value, 'Your school');
  setText('card-grade', $('grade').value, 'Your grade');
  $('card-bio').textContent = $('bio').value.trim() || 'Your story can live here — if you choose to share it.';
  $('card-bio').hidden = !$('show-bio').checked || !$('bio').value.trim();
  $('card-portrait').querySelector('span').textContent = initials(name);
}
inputs.forEach(input => input.addEventListener('input', updateCard));
$('show-bio').addEventListener('change', updateCard);
photoInput.addEventListener('change', () => {
  const file = photoInput.files[0]; if (!file) return;
  if (photoUrl) URL.revokeObjectURL(photoUrl);
  photoUrl = URL.createObjectURL(file);
  const image = $('photo-preview'); image.src = photoUrl; image.hidden = false;
  $('photo-placeholder').hidden = true;
  const portrait = $('card-portrait'); portrait.classList.add('has-image');
  portrait.querySelector('img')?.remove();
  const cardImage = document.createElement('img'); cardImage.src = photoUrl; cardImage.alt = 'Profile photo preview'; portrait.append(cardImage);
});
$('profile-form').addEventListener('submit', (event) => {
  event.preventDefault();
  if (!$('profile-form').checkValidity()) { $('profile-form').reportValidity(); return; }
  const profile = { name:$('name').value, role:$('role').value, school:$('school').value, grade:$('grade').value, bio:$('bio').value, showBio:$('show-bio').checked };
  localStorage.setItem('aboutUsProfile', JSON.stringify(profile));
  $('form-message').textContent = 'Profile saved locally. Your About Us preview is ready.';
});
const saved = localStorage.getItem('aboutUsProfile');
if (saved) { const data = JSON.parse(saved); Object.entries(data).forEach(([key,value]) => { if ($(key)) $(key).type === 'checkbox' ? $(key).checked=value : $(key).value=value; }); updateCard(); }
