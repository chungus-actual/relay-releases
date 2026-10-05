(async () => await new Promise(resolve => {
  let workerBlocked = false, connectBlocked = false;
  const finish = value => {
    clearTimeout(timeout);
    removeEventListener('securitypolicyviolation', violation);
    resolve(value);
  };
  const violation = event => {
    if (event.effectiveDirective === 'worker-src') workerBlocked = true;
    if (event.effectiveDirective === 'connect-src') connectBlocked = true;
    if (workerBlocked && connectBlocked) finish(true);
  };
  const timeout = setTimeout(() => finish(false), 5000);
  addEventListener('securitypolicyviolation', violation);
  try { new Worker(new URL('terminal.js', location.href)); } catch {}
  fetch('https://example.com/').catch(() => {});
}))()
