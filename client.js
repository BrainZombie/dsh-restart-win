/**
 * dsh-restart-win —— 浏览器半端（右栏「DSH 重启」面板）。
 *
 * 面板只做三件事：看状态、发动作、看回显。
 *   - 状态：hostKind / 实测端口 / 主进程与宿主 pid / HTTP / profile / 版本，8 秒自动刷新；
 *   - 动作：刷新、演练、深度验证、安全重启、只停、只拉；危险动作要点两次确认；
 *   - 回显：动作触发的 detached run 用 runId 轮询结果文件，逐步渲染引擎的 steps，
 *     并把最近的 restart-history 摘要列在下面。重启会把宿主杀掉，所以 runId 存在
 *     localStorage 里，面板重载后继续轮询同一个 run。
 *
 * 走宿主同源 cookie，不额外拿 token。本文件是手工维护的 __ModuleLoader__ bundle
 * （与 dsh-card-library 同一约定），不含 JSX；改完 `node --check client.js`。
 */
// 宿主在某些安装形态下会把同一个 bundle 执行两次（scoped link: 包实测）：第二次会触发
// client-modules 的 duplicate factory registration，整个插件被丢弃。这里做幂等。
if (!window.__dshRestartWinBundleLoaded) {
window.__dshRestartWinBundleLoaded = true
window.__ModuleLoader__.load({
  // 必须是**包名**：client 加载器按 manifest 的 id（= 包名）把 factory 与插件记录对上，
  // 写成短名只会注册 factory、永远不调用 apply（实测：面板不出现且没有任何报错）。
  id: '@brainzombie/dsh-restart-win',
  factory(require) {
    var React = require('react')
    var h = React.createElement

    var ID = 'dsh-restart-win'
    var PREFIX = '/dsh-restart-win'
    var STORE_KEY = 'dsh-restart-win.run'

    // 只用 DSH 的主题 token，深浅色都跟。
    var C = {
      text: 'var(--dsw-alias-label-primary, CanvasText)',
      dim: 'var(--dsw-alias-label-secondary, GrayText)',
      line: 'var(--dsw-alias-border-l2, rgba(128,128,128,0.28))',
      brand: 'var(--dsw-alias-brand-primary, #4b7bec)',
      ok: 'var(--dsw-alias-state-success-primary, #2f9e44)',
      warn: 'var(--dsw-alias-state-warn-primary, #e8590c)',
      danger: 'var(--dsw-alias-state-error-primary, #e03131)',
      soft: 'var(--dsw-alias-bg-layer-2, rgba(128,128,128,0.09))',
      soft2: 'var(--dsw-alias-bg-layer-3, rgba(128,128,128,0.15))',
      panel: 'var(--dsw-alias-bg-layer-1, Canvas)',
    }
    var MONO = 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace'

    // ─────────────────────────────────────────────────────── 小工具
    function Glyph(size) {
      return h('svg', {
        viewBox: '0 0 16 16', width: size || 16, height: size || 16, fill: 'none',
        stroke: 'currentColor', strokeWidth: 1.35, strokeLinecap: 'round', strokeLinejoin: 'round',
        'aria-hidden': true, style: { display: 'block' },
      },
        h('path', { d: 'M13.2 6.4 A5.4 5.4 0 1 0 13.4 9.6' }),
        h('path', { d: 'M13.4 2.9 V6.6 H9.7' }),
        h('path', { d: 'M8 5.6 V8.2 L9.9 9.4' }))
    }

    function text(value, fallback) {
      if (value === null || value === undefined || value === '') return fallback === undefined ? '—' : fallback
      return String(value)
    }

    function fmtTime(iso) {
      if (!iso) return '—'
      var d = new Date(iso)
      if (isNaN(d.getTime())) return String(iso)
      var pad = function (n) { return n < 10 ? '0' + n : '' + n }
      return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ' ' +
        pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds())
    }

    function api(path, options) {
      return fetch(PREFIX + path, options).then(function (res) {
        return res.json().then(function (payload) { return payload }).catch(function () {
          return { ok: false, error: 'HTTP ' + res.status }
        })
      })
    }

    function envelopeOf(value) {
      if (!value) return null
      if (value.envelope && typeof value.envelope === 'object') return value.envelope
      if (value.detail && value.detail.envelope && typeof value.detail.envelope === 'object') return value.detail.envelope
      return null
    }

    function stepsOf(value) {
      var env = envelopeOf(value)
      if (env && Array.isArray(env.steps)) return env.steps
      if (value && Array.isArray(value.steps)) return value.steps
      return []
    }

    // ─────────────────────────────────────────────────────── 样式
    var S = {
      root: { display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, fontSize: 12, color: C.text },
      scroll: { overflowY: 'auto', padding: '10px 12px 18px', display: 'flex', flexDirection: 'column', gap: 10 },
      card: { border: '1px solid ' + C.line, borderRadius: 8, background: C.soft, padding: '10px 12px' },
      row: { display: 'flex', justifyContent: 'space-between', gap: 10, padding: '2px 0' },
      label: { color: C.dim },
      value: { fontFamily: MONO, textAlign: 'right', wordBreak: 'break-all' },
      buttons: { display: 'flex', flexWrap: 'wrap', gap: 6 },
      btn: {
        border: '1px solid ' + C.line, background: C.soft2, color: C.text, borderRadius: 6,
        padding: '5px 10px', fontSize: 12, cursor: 'pointer', lineHeight: 1.3,
      },
      btnPrimary: {
        border: '1px solid ' + C.brand, background: C.brand, color: '#fff', borderRadius: 6,
        padding: '5px 10px', fontSize: 12, cursor: 'pointer', lineHeight: 1.3,
      },
      btnDanger: {
        border: '1px solid ' + C.danger, background: 'transparent', color: C.danger, borderRadius: 6,
        padding: '5px 10px', fontSize: 12, cursor: 'pointer', lineHeight: 1.3,
      },
      btnOff: { opacity: 0.45, cursor: 'default' },
      sectionTitle: { fontWeight: 600, marginBottom: 6 },
      log: {
        fontFamily: MONO, fontSize: 11, lineHeight: 1.5, whiteSpace: 'pre-wrap', wordBreak: 'break-word',
        maxHeight: 260, overflowY: 'auto', background: C.soft, borderRadius: 6, padding: '8px 10px',
      },
      ok: { color: C.ok },
      warn: { color: C.warn },
      danger: { color: C.danger },
      dim: { color: C.dim },
      chip: {
        display: 'inline-block', padding: '1px 6px', borderRadius: 999, border: '1px solid ' + C.line,
        fontSize: 10.5, color: C.dim, marginLeft: 6,
      },
    }

    // ─────────────────────────────────────────────────────── 状态卡
    function StatusCard(props) {
      var state = props.state
      if (state.loading && !state.value) {
        return h('div', { style: S.card }, h('div', { style: S.dim }, '读取状态…'))
      }
      if (state.error && !state.value) {
        return h('div', { style: S.card },
          h('div', { style: S.danger }, '读状态失败：' + state.error))
      }
      var value = state.value || {}
      var status = value.status || {}
      var inst = Array.isArray(status.instances) && status.instances.length ? status.instances[0] : null
      var okState = value.ok === true
      var rows = [
        ['宿主形态', status.hostKind === 'desktop' ? 'DSH Desktop（Electron）' : 'dsh web'],
        ['端口', text(status.port) + (status.configuredPort !== undefined ? '（配置 ' + text(status.configuredPort) + '，来源 ' + text(status.portSource) + '）' : '')],
        ['主进程', text(status.mainPid)],
        ['宿主进程', inst ? text(inst.pid) + ' · ' + text(inst.source) : '未发现'],
        ['HTTP', text(status.http) + (status.serving ? '（服务中）' : '（无响应）')],
        ['profile', text(status.profile)],
        ['版本', text(status.version)],
      ]
      return h('div', { style: S.card },
        h('div', { style: S.row },
          h('div', { style: S.sectionTitle }, '当前实例'),
          h('div', { style: okState ? S.ok : S.danger }, okState ? 'ok' : text(value.error, 'failed'))),
        rows.map(function (pair) {
          return h('div', { key: pair[0], style: S.row },
            h('span', { style: S.label }, pair[0]),
            h('span', { style: S.value }, pair[1]))
        }),
        status.launchUrl ? h('div', { style: { marginTop: 6, display: 'flex', gap: 6, alignItems: 'center' } },
          h('span', { style: S.label }, '访问地址'),
          h('code', { style: { fontFamily: MONO, fontSize: 10.5, wordBreak: 'break-all', flex: 1 } }, status.launchUrl),
          h('button', {
            style: S.btn,
            onClick: function () {
              try { navigator.clipboard.writeText(status.launchUrl) } catch (e) { /* ignore */ }
            },
          }, '复制')) : null,
        state.error ? h('div', { style: { marginTop: 6, color: C.warn } }, '刷新告警：' + state.error) : null)
    }

    // ─────────────────────────────────────────────────────── 动作回显
    function RunCard(props) {
      var run = props.run
      if (!run) return null
      var value = run.value || {}
      var steps = stepsOf(value)
      var state = run.running ? 'running' : (value.state || (value.ok ? 'ok' : 'failed'))
      var color = state === 'ok' ? S.ok : (state === 'running' ? S.dim : S.danger)
      return h('div', { style: S.card },
        h('div', { style: S.row },
          h('div', { style: S.sectionTitle }, '动作：' + (run.label || '—')),
          h('div', { style: color }, state + (value.exitCode !== undefined && value.exitCode !== null ? ' · exit ' + value.exitCode : ''))),
        run.runId ? h('div', { style: { ...S.row, fontSize: 11 } },
          h('span', { style: S.label }, 'runId'),
          h('span', { style: { fontFamily: MONO } }, run.runId)) : null,
        run.waitingHost ? h('div', { style: S.warn }, '宿主正在重启，等待结果文件…') : null,
        value.summary ? h('div', { style: S.row },
          h('span', { style: S.label }, '结论'),
          h('span', { style: S.value }, String(value.summary))) : null,
        value.error || (value.ok === false && !value.summary) ? h('div', { style: S.danger },
          '错误：' + text(value.error, '未知')) : null,
        steps.length ? h('div', { style: S.log },
          steps.slice(-30).map(function (step, index) {
            var mark = step.state === 'ok' ? '✓' : (step.state === 'warn' ? '!' : (step.state === 'skip' ? '·' : '✗'))
            var color2 = step.state === 'ok' ? C.ok : (step.state === 'warn' ? C.warn : (step.state === 'skip' ? C.dim : C.danger))
            return h('div', { key: index, style: { color: color2 } },
              mark + ' ' + text(step.step) + '  ' + text(step.detail, ''))
          })) : h('div', { style: S.dim }, run.running ? '等待引擎写入步骤…' : '没有步骤输出。'),
        value.resultFile ? h('div', { style: { ...S.row, fontSize: 10.5 } },
          h('span', { style: S.label }, '结果文件'),
          h('span', { style: { fontFamily: MONO, wordBreak: 'break-all' } }, value.resultFile)) : null)
    }

    // ─────────────────────────────────────────────────────── 历史
    function HistoryCard(props) {
      // 引擎每次 -Status 也会写一条审计；面板的「最近重启」只看真正的动作。
      var entries = (props.entries || []).filter(function (entry) { return entry && entry.result !== 'status' })
      return h('div', { style: S.card },
        h('div', { style: S.sectionTitle }, '最近重启'),
        !entries.length ? h('div', { style: S.dim }, '暂无记录。') :
          entries.map(function (entry, index) {
            var color = entry.result === 'restarted-ok' ? S.ok : (entry.rc === 0 ? S.dim : S.danger)
            return h('div', { key: index, style: { ...S.row, fontSize: 11 } },
              h('span', { style: { fontFamily: MONO } }, fmtTime(entry.ts)),
              h('span', { style: color },
                text(entry.result) + (entry.rc !== null ? ' · rc ' + entry.rc : '') +
                (entry.port ? ' · 端口 ' + entry.port : '') +
                (entry.newPid ? ' · 新宿主 ' + entry.newPid : '')))
          }))
    }

    // ─────────────────────────────────────────────────────── 面板
    function Panel() {
      var statusState = React.useState({ loading: true, error: null, value: null })
      var status = statusState[0]
      var setStatus = statusState[1]

      var runState = React.useState(null)
      var run = runState[0]
      var setRun = runState[1]

      var busyState = React.useState('')
      var busy = busyState[0]
      var setBusy = busyState[1]

      var confirmState = React.useState('')
      var confirm = confirmState[0]
      var setConfirm = confirmState[1]

      var historyState = React.useState([])
      var history = historyState[0]
      var setHistory = historyState[1]

      var timer = React.useRef(null)
      var alive = React.useRef(true)
      var busyRef = React.useRef('')
      var runningRef = React.useRef(false)

      var refresh = React.useCallback(function () {
        // 动作在跑的时候别刷状态：引擎的 status 也要跑一次脚本，纯属抢资源。
        if (busyRef.current || runningRef.current) return
        api('/api/status').then(function (payload) {
          if (!alive.current) return
          if (!payload || typeof payload !== 'object') payload = { ok: false, error: '空响应' }
          setStatus({ loading: false, error: payload.ok === true ? null : text(payload.error, 'status failed'), value: payload })
          if (payload.ok === true && payload.status) {
            var kinds = payload.status.hostKind
            var p = payload.status.resolvedPort || payload.status.port
            if (kinds && p) { /* no-op: kept for readability */ }
          }
        }).catch(function (err) {
          if (!alive.current) return
          setStatus(function (prev) {
            return { loading: false, error: String((err && err.message) || err), value: prev ? prev.value : null }
          })
        })
        api('/api/history?limit=5').then(function (payload) {
          if (alive.current && payload && Array.isArray(payload.entries)) setHistory(payload.entries)
        }).catch(function () { /* ignore */ })
      }, [])

      var stopPolling = React.useCallback(function () {
        if (timer.current) { clearTimeout(timer.current); timer.current = null }
      }, [])

      var poll = React.useCallback(function (runId, label) {
        stopPolling()
        runningRef.current = true
        setRun({ runId: runId, label: label, value: null, running: true, waitingHost: false })
        function tick() {
          if (!alive.current) return
          api('/api/result?runId=' + encodeURIComponent(runId) + '&waitMs=5000').then(function (payload) {
            if (!alive.current) return
            if (!payload || typeof payload !== 'object') payload = { ok: false, state: 'failed', error: '空响应' }
            setRun({ runId: runId, label: label, value: payload, running: payload.state === 'running', waitingHost: false })
            if (payload.state === 'running') {
              timer.current = setTimeout(tick, 1200)
            } else {
              runningRef.current = false
              try { localStorage.removeItem(STORE_KEY) } catch (e) { /* ignore */ }
              refresh()
            }
          }).catch(function () {
            if (!alive.current) return
            // 重启中宿主会短暂消失：继续等，别把一次成功的重启报成失败。
            setRun(function (prev) {
              return Object.assign({}, prev || {}, { runId: runId, label: label, running: true, waitingHost: true })
            })
            timer.current = setTimeout(tick, 2000)
          })
        }
        tick()
      }, [refresh, stopPolling])

      React.useEffect(function () {
        alive.current = true
        refresh()
        var interval = setInterval(refresh, 10000)
        var saved = null
        try { saved = localStorage.getItem(STORE_KEY) } catch (e) { saved = null }
        if (saved) poll(saved, '恢复上次运行')
        return function () {
          alive.current = false
          clearInterval(interval)
          if (timer.current) clearTimeout(timer.current)
        }
      }, [])

      function act(action) {
        if (busy) return
        if (action === 'restart' || action === 'stop') {
          if (confirm !== action) {
            setConfirm(action)
            setTimeout(function () {
              if (alive.current) setConfirm(function (prev) { return prev === action ? '' : prev })
            }, 4000)
            return
          }
          setConfirm('')
        }
        setBusy(action)
        busyRef.current = action
        api('/api/action', {
          method: 'POST',
          headers: { 'content-type': 'application/json' },
          body: JSON.stringify({ action: action }),
        }).then(function (payload) {
          if (!alive.current) return
          setBusy('')
          busyRef.current = ''
          if (!payload || payload.ok !== true) {
            setRun({ runId: null, label: action, value: payload || { ok: false, error: '空响应' }, running: false, waitingHost: false })
            return
          }
          if (payload.runId) {
            try { localStorage.setItem(STORE_KEY, payload.runId) } catch (e) { /* ignore */ }
            poll(payload.runId, action)
          } else {
            setRun({ runId: null, label: action, value: payload, running: false, waitingHost: false })
            refresh()
          }
        }).catch(function (err) {
          if (!alive.current) return
          setBusy('')
          busyRef.current = ''
          setRun({ runId: null, label: action, value: { ok: false, error: String((err && err.message) || err) }, running: false, waitingHost: false })
        })
      }

      function button(label, action, options) {
        var opts = options || {}
        var isBusy = busy === action
        var isConfirm = confirm === action
        var style = opts.danger ? S.btnDanger : (opts.primary ? S.btnPrimary : S.btn)
        if (busy || isBusy) style = Object.assign({}, style, S.btnOff)
        return h('button', {
          key: action,
          style: style,
          disabled: !!busy,
          onClick: function () { act(action) },
        }, isBusy ? label + '…' : (isConfirm ? '再点一次确认' : label))
      }

      var runningKnown = status.value && status.value.status && status.value.status.serving

      return h('div', { style: S.root },
        h('div', { style: S.scroll },
          h(StatusCard, { state: status }),
          h('div', { style: S.card },
            h('div', { style: S.sectionTitle }, '操作'),
            h('div', { style: S.buttons },
              button('刷新', 'refresh'),
              button('演练', 'dry_run'),
              button('深度验证', 'preflight'),
              button('安全重启', 'restart', { primary: true }),
              button('只停', 'stop', { danger: true }),
              button('只拉', 'start')),
            h('div', { style: { marginTop: 6, fontSize: 10.5, color: C.dim } },
              runningKnown
                ? '安全重启会先深度验证，再杀 Electron 主进程整棵树并重放 exe；当前会话会中断，重启后可续跑。'
                : '没有发现运行中的宿主：安全重启会走冷启动（需要 boot-record 或 App 路径）。')),
          h(RunCard, { run: run }),
          h(HistoryCard, { entries: history })))
    }

    // 面板里任何一次抛错都在面板内显示，而不是留一个空白栏。
    class PanelBoundary extends React.Component {
      constructor(props) {
        super(props)
        this.state = { error: null }
      }

      static getDerivedStateFromError(error) {
        return { error: error }
      }

      render() {
        if (!this.state.error) return this.props.children
        var message = String((this.state.error && this.state.error.message) || this.state.error)
        return h('div', { style: { padding: '14px 16px', fontSize: 12, color: C.danger } },
          'DSH 重启面板出错：' + message)
      }
    }

    function Guarded() {
      return h(PanelBoundary, null, h(Panel))
    }

    function ChipTitle() {
      return h('span', { style: { fontSize: 12 } }, 'DSH 重启')
    }

    // ─────────────────────────────────────────── 远程停止（非回环页面兜底）
    // 背景：经 *.ts.net 这类反向代理域名访问时，部分会话的原生停止按钮点了没反应
    // （ui-conversation 里 scopedConversation 取不到 scope 会同步抛错并被 catch 吞掉，
    // 于是「按钮在、无请求、无报错」）。宿主侧 /api/session/cancel 的 RPC 是通的，
    // 这里给一个直连它的悬浮入口；只在非回环页面启用，本机 127.0.0.1 不出现。
    var REMOTE_STOP_ID = 'dsh-remote-stop-widget'
    var REMOTE_STOP_RS = { list: 5000 }

    function isLoopbackHost(name) {
      var host = String(name || '').toLowerCase()
      if (!host) return true
      return host === 'localhost' || host === '127.0.0.1' || host === '[::1]' || host === '::1' ||
        host.slice(-10) === '.localhost' || host.slice(0, 8) === '127.0.0.'
    }

    // 支持 `host`、`.suffix`、`*.suffix` 三种写法，与宿主 config.trustedHosts 同义。
    function hostMatches(pattern, host) {
      var p = String(pattern || '').toLowerCase().trim()
      if (!p) return false
      if (p.slice(0, 2) === '*.') return host.slice(-(p.length - 1)) === p.slice(1)
      if (p.charAt(0) === '.') return host === p.slice(1) || host.slice(-p.length) === p
      return host === p
    }

    function mk(tag, style, content) {
      var node = document.createElement(tag)
      if (style) node.setAttribute('style', style)
      if (content !== undefined && content !== null) node.textContent = String(content)
      return node
    }

    function rpcId() {
      return 'remote-stop-' + Date.now().toString(36) + '-' + Math.random().toString(36).slice(2, 8)
    }

    function fetchJson(url, options) {
      return fetch(url, options).then(function (res) {
        return res.json().catch(function () { return { ok: false, error: 'HTTP ' + res.status } })
      })
    }

    function cancelSession(sessionId) {
      return fetchJson('/api/session/cancel', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify({
          type: 'client-request',
          rpcId: rpcId(),
          method: 'session/cancel',
          payload: { args: { request: { sessionId: sessionId } } },
        }),
      })
    }

    // 标题不在 sessions 列表里，得从归档插件的 sidebar-state 拿（页面内 ~0.9s）。
    // 拿不到就退回短 id，面板照样能用。
    function loadTitles() {
      return fetchJson('/archived-sessions/sidebar-state').then(function (payload) {
        var titles = (payload && (payload.titles || (payload.value && payload.value.titles))) || {}
        return titles && typeof titles === 'object' ? titles : {}
      }).catch(function () { return {} })
    }

    function shortId(id) {
      var raw = String(id || '')
      var tail = raw.slice(-4)
      return 'session…' + tail
    }

    function cwdLabel(cwd) {
      if (!cwd) return ''
      var parts = String(cwd).split(/[\\/]+/).filter(Boolean)
      return parts.length ? parts[parts.length - 1] : String(cwd)
    }

    function agoLabel(ms) {
      if (!ms) return ''
      var diff = Date.now() - ms
      if (diff < 0) diff = 0
      var minutes = Math.floor(diff / 60000)
      if (minutes < 1) return '刚刚'
      if (minutes < 60) return minutes + ' 分钟'
      var hours = Math.floor(minutes / 60)
      if (hours < 24) return hours + ' 小时 ' + (minutes % 60) + ' 分'
      return Math.floor(hours / 24) + ' 天'
    }

    function mountRemoteStop() {
      // 宿主外加载（单测、SSR 探针）时没有 document/location：直接放弃挂载。
      if (typeof document === 'undefined' || typeof location === 'undefined') return null
      var host = String(location.hostname || '').toLowerCase()
      if (isLoopbackHost(host)) return null
      var existing = document.getElementById(REMOTE_STOP_ID)
      if (existing && existing.parentNode) existing.parentNode.removeChild(existing)

      var wrap = mk('div', [
        'position:fixed', 'right:10px', 'top:41vh', 'z-index:2147482000',
        'display:flex', 'flex-direction:row-reverse', 'align-items:flex-start', 'gap:8px',
        'font:12px/1.4 system-ui,-apple-system,"Segoe UI",sans-serif',
      ].join(';'))
      wrap.id = REMOTE_STOP_ID

      var button = mk('button', [
        'width:34px', 'height:34px', 'border-radius:999px', 'cursor:pointer',
        'border:1px solid ' + C.line, 'background:' + C.soft2, 'color:' + C.text,
        'font-size:15px', 'line-height:1', 'display:flex', 'align-items:center', 'justify-content:center',
        'box-shadow:0 4px 14px rgba(0,0,0,0.22)',
      ].join(';'), '⏹')
      button.type = 'button'
      button.title = '远程停止进行中的会话'
      button.setAttribute('aria-label', '远程停止')

      var panel = mk('div', [
        'display:none', 'width:300px', 'max-height:52vh', 'overflow:auto',
        'border:1px solid ' + C.line, 'border-radius:10px', 'background:' + C.panel,
        'box-shadow:0 10px 30px rgba(0,0,0,0.28)', 'padding:10px 12px',
      ].join(';'))

      var head = mk('div', 'display:flex;align-items:center;justify-content:space-between;gap:8px')
      head.appendChild(mk('div', 'font-weight:600', '进行中的会话'))
      var close = mk('button', 'border:0;background:transparent;color:' + C.dim + ';cursor:pointer;font-size:14px', '×')
      close.type = 'button'
      close.title = '收起'
      head.appendChild(close)

      var tip = mk('div', 'color:' + C.dim + ';margin:4px 0 8px', '只列出有进行中回合的会话；停止走宿主 /api/session/cancel。')
      var list = mk('div', 'display:flex;flex-direction:column;gap:6px')
      var foot = mk('div', 'display:flex;justify-content:space-between;align-items:center;gap:8px;margin-top:8px')
      var status = mk('span', 'color:' + C.dim, '')
      var refresh = mk('button', 'border:1px solid ' + C.line + ';background:transparent;color:' + C.text + ';border-radius:6px;padding:2px 8px;cursor:pointer;font-size:11px', '刷新')
      refresh.type = 'button'
      foot.appendChild(status)
      foot.appendChild(refresh)

      panel.appendChild(head)
      panel.appendChild(tip)
      panel.appendChild(list)
      panel.appendChild(foot)
      wrap.appendChild(button)
      wrap.appendChild(panel)
      document.body.appendChild(wrap)

      var titles = {}
      var timer = null
      var open = false

      function setStatus(message) {
        status.textContent = message || ''
      }

      function renderRows(items) {
        list.textContent = ''
        if (!items.length) {
          list.appendChild(mk('div', 'color:' + C.dim + ';padding:6px 0', '当前没有进行中的会话。'))
          return
        }
        items.forEach(function (item) {
          var row = mk('div', 'border:1px solid ' + C.line + ';border-radius:8px;padding:6px 8px;display:flex;align-items:center;justify-content:space-between;gap:8px')
          var meta = mk('div', 'min-width:0;display:flex;flex-direction:column;gap:2px')
          var title = titles[item.sessionId] || shortId(item.sessionId)
          var name = mk('div', 'font-weight:600;overflow:hidden;text-overflow:ellipsis;white-space:nowrap', title)
          name.title = String(item.sessionId)
          meta.appendChild(name)
          var bits = []
          if (item.cwd) bits.push(cwdLabel(item.cwd))
          if (item.runningSince) bits.push('已运行 ' + agoLabel(item.runningSince))
          meta.appendChild(mk('div', 'color:' + C.dim + ';font-size:11px', bits.join(' · ') || '进行中'))
          var stop = mk('button', 'border:1px solid ' + C.danger + ';background:transparent;color:' + C.danger + ';border-radius:6px;padding:3px 9px;cursor:pointer;font-size:11px', '停止')
          stop.type = 'button'
          stop.addEventListener('click', function () {
            stop.disabled = true
            stop.textContent = '停止中'
            setStatus('正在停止 ' + title + ' …')
            cancelSession(item.sessionId).then(function (payload) {
              var result = (payload && payload.result) || payload || {}
              var ok = result.ok === true
              var accepted = !!(result.value && result.value.accepted)
              if (ok && accepted) setStatus('已停止：' + title)
              else if (ok) setStatus('该会话当前没有进行中的回合：' + title)
              else {
                var error = (result.error && (result.error.message || result.error.code)) || '取消失败'
                setStatus('停止失败：' + error)
              }
            }).catch(function (error) {
              setStatus('停止失败：' + String((error && error.message) || error))
            }).then(function () {
              stop.disabled = false
              stop.textContent = '停止'
              load()
            })
          })
          row.appendChild(meta)
          row.appendChild(stop)
          list.appendChild(row)
        })
      }

      function load() {
        return Promise.all([
          fetchJson(PREFIX + '/api/sessions'),
          Object.keys(titles).length ? Promise.resolve(titles) : loadTitles(),
        ]).then(function (results) {
          var payload = results[0] || {}
          if (results[1] && typeof results[1] === 'object') titles = results[1]
          if (payload.ok === false) {
            list.textContent = ''
            list.appendChild(mk('div', 'color:' + C.warn + ';padding:6px 0', '会话列表不可用：' + (payload.error || 'unknown')))
            setStatus('')
            return
          }
          var items = (payload.items || []).filter(function (item) { return item && item.running })
          renderRows(items)
          setStatus(items.length ? items.length + ' 个进行中' : '空闲')
        }).catch(function (error) {
          list.textContent = ''
          list.appendChild(mk('div', 'color:' + C.danger + ';padding:6px 0', '读取失败：' + String((error && error.message) || error)))
        })
      }

      function show() {
        open = true
        panel.style.display = 'block'
        load()
        if (timer) clearInterval(timer)
        timer = setInterval(function () { if (open && document.visibilityState !== 'hidden') load() }, REMOTE_STOP_RS.list)
      }

      function hide() {
        open = false
        panel.style.display = 'none'
        if (timer) { clearInterval(timer); timer = null }
      }

      button.addEventListener('click', function () { if (open) hide(); else show() })
      close.addEventListener('click', hide)
      refresh.addEventListener('click', function () { setStatus('刷新中…'); load() })

      return function dispose() {
        hide()
        if (wrap.parentNode) wrap.parentNode.removeChild(wrap)
      }
    }

    // meta 里的 trustedHosts 决定是否在这个域名出现；拿不到时退回 *.ts.net。
    function shouldMountRemoteStop() {
      if (typeof document === 'undefined' || typeof location === 'undefined') return Promise.resolve(false)
      var host = String(location.hostname || '').toLowerCase()
      if (isLoopbackHost(host)) return Promise.resolve(false)
      return fetchJson(PREFIX + '/api/meta').then(function (payload) {
        var hosts = (payload && payload.trustedHosts) || []
        if (Array.isArray(hosts) && hosts.length) {
          return hosts.some(function (pattern) { return hostMatches(pattern, host) })
        }
        return host.slice(-7) === '.ts.net'
      }).catch(function () { return host.slice(-7) === '.ts.net' })
    }

    function definition() {
      return {
        id: ID,
        kind: ID,
        keepMounted: true,
        title: function () { return 'DSH 重启' },
        guide: [{
          id: ID,
          order: 64,
          title: function () { return 'DSH 重启' },
          description: function () { return '安全重启 DSH Desktop：状态、演练、深度验证、重启与结果回显' },
          icon: Glyph,
        }],
      }
    }

    return {
      inject: ['slots', 'sidebarRightTabs'],
      apply(ctx) {
        ctx.effect(function () { return ctx.sidebarRightTabs.register(definition()) },
          'dsh-restart-win: tab type')
        ctx.effect(function () {
          return ctx.slots.inject('sidebar.right.pane.tab', function () {
            return ctx.slots.register({ name: 'sidebar.right.pane.tab', key: ID }, Guarded)
          })
        }, 'dsh-restart-win: tab body')
        ctx.effect(function () {
          return ctx.slots.inject('sidebar.right.pane.tab.title', function () {
            return ctx.slots.register({ name: 'sidebar.right.pane.tab.title', key: ID }, ChipTitle)
          })
        }, 'dsh-restart-win: tab title')
        // 远程（非回环）页面才挂悬浮停止入口；dispose 负责摘掉 DOM 与定时器。
        ctx.effect(function () {
          var dispose = null
          var cancelled = false
          shouldMountRemoteStop().then(function (enabled) {
            if (!enabled || cancelled) return
            dispose = mountRemoteStop()
          })
          return function () {
            cancelled = true
            if (typeof dispose === 'function') dispose()
          }
        }, 'dsh-restart-win: remote stop')
      },
    }
  },
})

}
