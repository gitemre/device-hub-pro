// With reduced motion, the clips stay paused and get their controls.
const still = matchMedia('(prefers-reduced-motion: reduce)').matches;
if (still) {
  document.querySelectorAll('video[autoplay]').forEach(v => {
    v.removeAttribute('autoplay');
    v.pause();
    v.controls = true;
  });
}

// iPhone Duo page: the hinge scale. The presets are the angles apps read at Device Hub Pro's
// postures; a preset moves the hinge over about half a second, as the app does.
const hinge = document.getElementById('hinge');
if (hinge) {
  const presets = [
    { name: 'Closed', angle: 0 },
    { name: 'Tent', angle: 71.1 },
    { name: 'Laptop', angle: 104.2 },
    { name: 'Partially Open', angle: 127.8 },
    { name: 'Open', angle: 180 },
  ];
  const lid = document.getElementById('hinge-lid');
  const arc = document.getElementById('hinge-arc');
  const outAngle = document.getElementById('out-angle');
  const outPosture = document.getElementById('out-posture');
  const cx = 200, cy = 190, len = 150, r = 34;
  let anim = 0;

  const draw = deg => {
    const t = (deg * Math.PI) / 180;
    lid.setAttribute('x2', (cx - len * Math.cos(t)).toFixed(1));
    lid.setAttribute('y2', (cy - len * Math.sin(t)).toFixed(1));
    const ax = cx - r * Math.cos(t), ay = cy - r * Math.sin(t);
    arc.setAttribute('d', deg < 0.5 ? '' : `M ${cx - r} ${cy} A ${r} ${r} 0 0 1 ${ax.toFixed(1)} ${ay.toFixed(1)}`);
    outAngle.textContent = `${deg.toFixed(1)}°`;
    const near = presets.find(p => Math.abs(p.angle - deg) < 0.6);
    outPosture.textContent = near ? near.name : 'Hinge slider';
    document.querySelectorAll('[data-angle]').forEach(b =>
      b.setAttribute('aria-pressed', String(near && Number(b.dataset.angle) === near.angle)));
  };

  hinge.addEventListener('input', () => { cancelAnimationFrame(anim); draw(Number(hinge.value)); });

  document.querySelectorAll('[data-angle]').forEach(button => {
    button.addEventListener('click', () => {
      cancelAnimationFrame(anim);
      const from = Number(hinge.value), to = Number(button.dataset.angle);
      if (still) { hinge.value = to; draw(to); return; }
      const start = performance.now(), ms = 500;
      const step = now => {
        const k = Math.min(1, (now - start) / ms);
        const eased = 1 - Math.pow(1 - k, 3);
        const deg = from + (to - from) * eased;
        hinge.value = deg;
        draw(k === 1 ? to : deg);
        if (k < 1) anim = requestAnimationFrame(step);
      };
      anim = requestAnimationFrame(step);
    });
  });

  draw(Number(hinge.value));
}
