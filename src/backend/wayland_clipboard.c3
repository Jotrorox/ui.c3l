// Stable wl_data_device v1. Transfers are bounded and polled with the display,
// so a slow clipboard owner cannot block keyboard, paint, or close events.
module ui::backend @feat(LINUX);
import libc, std::math;

struct WOffer
{
	void* proxy;
	ZString utf8;
	bool plain;
	WOffer* next;
}
struct WSource
{
	void* proxy;
	String text;
	WSource* next;
}
struct WSend
{
	int fd;
	String text;
	sz offset;
	long deadline;
	WSend* next;
}
struct WClipboard
{
	void* manager;
	void* device;
	uint manager_name;
	uint serial;
	WOffer* offers;
	WOffer* selection;
	WOffer* drag;
	WSource* sources;
	WSend* sends;
	uint send_count;
	bool reading;
	int fd;
	char[4097] bytes;
	sz length;
	long deadline;
	ClipboardRequest request;
}

extern fn int clipboard_pipe(int[2]* fds, int flags) @cname("pipe2");
extern fn int clipboard_fcntl(int fd, int command, int flags) @cname("fcntl");
// Block SIGPIPE only around a write on this thread. Consume a newly generated
// signal on EPIPE before restoring the application's original signal mask.
extern fn int clipboard_sigmask(int how, ulong* set, ulong* old) @cname("pthread_sigmask");
extern fn int clipboard_sigpending(ulong* set) @cname("sigpending");
extern fn int clipboard_sigwait(ulong* set, void* info, WTime* timeout) @cname("sigtimedwait");

fn sz clipboard_pipe_write(int fd, char[] bytes) @private
{
	ulong[16] block;
	ulong[16] old;
	ulong[16] pending;
	block[0] = 1 << 12; // SIGPIPE = 13 on Linux.
	if (clipboard_sigmask(0, &block[0], &old[0])) return -1; // SIG_BLOCK
	(void)clipboard_sigpending(&pending[0]);
	sz result = libc::write(fd, bytes.ptr, (usz)bytes.len);
	libc::Errno error = libc::errno();
	if (result < 0 && error == EPIPE && !(pending[0] & block[0]))
	{
		WTime immediate;
		while (clipboard_sigwait(&block[0], null, &immediate) < 0 && libc::errno() == EINTR) {}
	}
	(void)clipboard_sigmask(2, &old[0], null); // SIG_SETMASK
	libc::errno_set(error);
	return result;
}

fn void? WaylandWindow.clipboard_device(&self)
{
	if (!self.clipboard.manager || !self.seat || self.clipboard.device) return;
	WArg[2] args = { { .o = null }, { .o = self.seat } };
	self.clipboard.device = self.construct(self.clipboard.manager, 1, self.api.data_device, 1, args[..])!;
	self.listen(self.clipboard.device)!;
}

fn void WaylandWindow.drop_offer(&self, WOffer* offer)
{
	if (!offer) return;
	WOffer** link = &self.clipboard.offers;
	while (*link && *link != offer) link = &(*link).next;
	if (!*link) return;
	*link = offer.next;
	if (self.clipboard.selection == offer) self.clipboard.selection = null;
	if (self.clipboard.drag == offer) self.clipboard.drag = null;
	self.destroy_request(offer.proxy, 2);
	mem::free(offer);
}

fn void WaylandWindow.cancel_clipboard_read(&self)
{
	if (self.clipboard.reading) (void)close(self.clipboard.fd);
	self.clipboard.reading = false;
	self.clipboard.length = 0;
}

fn void WaylandWindow.dispose_clipboard(&self, bool manager = true)
{
	self.cancel_clipboard_read();
	while (self.clipboard.sends)
	{
		WSend* transfer = self.clipboard.sends;
		self.clipboard.sends = transfer.next;
		(void)close(transfer.fd);
		transfer.text.free(mem);
		mem::free(transfer);
	}
	self.clipboard.send_count = 0;
	while (self.clipboard.offers) self.drop_offer(self.clipboard.offers);
	while (self.clipboard.sources)
	{
		WSource* source = self.clipboard.sources;
		self.clipboard.sources = source.next;
		self.destroy_request(source.proxy, 1);
		source.text.free(mem);
		mem::free(source);
	}
	if (self.clipboard.device) self.api.destroy(self.clipboard.device); // v1 has no release request.
	self.clipboard.device = null;
	if (manager && self.clipboard.manager)
	{
		self.api.destroy(self.clipboard.manager);
		self.clipboard.manager = null;
	}
	self.clipboard.serial = 0;
}

fn bool wayland_clipboard_write(void* context, String text) @private
{
	WaylandWindow* window = context;
	if (!window.clipboard.device || !window.clipboard.serial) return false;
	uint count;
	for (WSource* source = window.clipboard.sources; source; source = source.next) count++;
	if (count >= 16) return false;
	if (catch failure = window.publish_clipboard(text)) { window.failure = failure; return false; }
	return true;
}

fn void? WaylandWindow.publish_clipboard(&self, String text)
{
	WArg[1] create;
	void* proxy = self.construct(self.clipboard.manager, 0, self.api.data_source, 1, create[..])!;
	defer catch self.destroy_request(proxy, 1);
	self.listen(proxy)!;
	WSource* source = mem::new(WSource, { .proxy = proxy, .text = text.copy(mem), .next = self.clipboard.sources });
	self.clipboard.sources = source;
	foreach (ZString mime : { "text/plain;charset=utf-8", "text/plain" })
	{
		WArg[1] offer = { { .s = mime } };
		self.request(proxy, 0, offer[..]);
	}
	WArg[2] select = { { .o = proxy }, { .u = self.clipboard.serial } };
	self.request(self.clipboard.device, 1, select[..]);
}

fn void wayland_clipboard_read(void* context, ClipboardRequest request) @private
{
	WaylandWindow* window = context;
	WOffer* offer = window.clipboard.selection;
	if (!offer || (!offer.utf8 && !offer.plain)) return;
	window.cancel_clipboard_read();
	int[2] fds;
	if (clipboard_pipe(&fds, 0x80000)) return; // O_CLOEXEC; only our read end is nonblocking.
	if (clipboard_fcntl(fds[0], 4, 0x800) < 0)
	{
		(void)close(fds[0]);
		(void)close(fds[1]);
		return;
	}
	WArg[2] receive = { { .s = offer.utf8 ? offer.utf8 : "text/plain" }, { .i = fds[1] } };
	window.request(offer.proxy, 1, receive[..]);
	(void)close(fds[1]); // libwayland duplicates the outgoing descriptor.
	window.clipboard.fd = fds[0];
	window.clipboard.reading = true;
	window.clipboard.request = request;
	window.clipboard.deadline = wayland_time() + 5000;
}

fn void WaylandWindow.read_clipboard(&self)
{
	WClipboard* clip = &self.clipboard;
	if (!clip.reading) return;
	if (wayland_time() >= clip.deadline || !self.view || clip.request.focus_epoch != self.view.focus_epoch ||
		clip.request.edit_epoch != self.view.edit_epoch) { self.cancel_clipboard_read(); return; }
	while (true)
	{
		sz count = libc::read(clip.fd, &clip.bytes[clip.length], (usz)(clip.bytes.len - clip.length));
		if (count < 0)
		{
			if (libc::errno() == EINTR) continue;
			if (libc::errno() == EAGAIN) return;
			self.cancel_clipboard_read();
			return;
		}
		if (!count)
		{
			clip.reading = false;
			(void)close(clip.fd);
			sz length = clip.length;
			clip.length = 0;
			self.view.paste_text((String)clip.bytes[:length], clip.request);
			return;
		}
		clip.length += count;
		if (clip.length > ui::TEXT_FIELD_LIMIT) { self.cancel_clipboard_read(); return; }
	}
}

fn void WaylandWindow.send_clipboard(&self)
{
	WSend** link = &self.clipboard.sends;
	while (*link)
	{
		WSend* transfer = *link;
		bool done = wayland_time() >= transfer.deadline;
		if (!done)
		{
			sz count = clipboard_pipe_write(transfer.fd, ((char[])transfer.text)[transfer.offset..]);
			if (count > 0) transfer.offset += count;
			done = transfer.offset == transfer.text.len || (count < 0 && libc::errno() != EAGAIN && libc::errno() != EINTR);
		}
		if (!done) { link = &transfer.next; continue; }
		*link = transfer.next;
		self.clipboard.send_count--;
		(void)close(transfer.fd);
		transfer.text.free(mem);
		mem::free(transfer);
	}
}

fn bool WaylandWindow.is_clipboard_proxy(&self, void* target)
{
	if (target == self.clipboard.device && target) return true;
	for (WOffer* offer = self.clipboard.offers; offer; offer = offer.next) if (target == offer.proxy) return true;
	for (WSource* source = self.clipboard.sources; source; source = source.next) if (target == source.proxy) return true;
	return false;
}

fn void? WaylandWindow.clipboard_event(&self, void* target, uint opcode, WArg* args)
{
	WClipboard* clip = &self.clipboard;
	if (target == clip.device)
	{
		if (opcode == 0)
		{
			WOffer* offer = mem::new(WOffer, { .proxy = args[0].o, .next = clip.offers });
			clip.offers = offer;
			self.listen(offer.proxy)!;
		}
		else if (opcode == 1 || opcode == 5) // drag enter or selection
		{
			void* proxy = args[opcode == 1 ? 4 : 0].o;
			WOffer* next;
			for (WOffer* offer = clip.offers; offer; offer = offer.next) if (offer.proxy == proxy) next = offer;
			WOffer* previous = opcode == 1 ? clip.drag : clip.selection;
			if (previous && previous != next) self.drop_offer(previous);
			if (opcode == 1) { clip.drag = next; }
			else { clip.selection = next; }
		}
		else if (opcode == 2) { self.drop_offer(clip.drag); } // drag leave
		else if (opcode == 4) { self.drop_offer(clip.drag); } // drag/drop unsupported
		return;
	}
	for (WOffer* offer = clip.offers; offer; offer = offer.next)
	{
		if (target != offer.proxy) continue;
		if (opcode == 0)
		{
			String mime = args[0].s.str_view();
			if (mime == "text/plain;charset=utf-8") offer.utf8 = "text/plain;charset=utf-8";
			if (mime == "text/plain;charset=UTF-8") offer.utf8 = "text/plain;charset=UTF-8";
			if (mime == "text/plain") offer.plain = true;
		}
		return;
	}
	WSource** link = &clip.sources;
	while (*link)
	{
		WSource* source = *link;
		if (source.proxy != target) { link = &source.next; continue; }
		if (opcode == 1) // send(mime, fd): own the fd even for unsupported MIME.
		{
			int fd = args[1].i;
			String mime = args[0].s.str_view();
			int flags = clipboard_fcntl(fd, 3, 0); // F_GETFL
			if ((mime != "text/plain;charset=utf-8" && mime != "text/plain") || clip.send_count >= 16 ||
				flags < 0 || clipboard_fcntl(fd, 4, flags | 0x800) < 0) { (void)close(fd); return; }
			WSend* transfer = mem::new(WSend, { .fd = fd, .text = source.text.copy(mem),
				.deadline = wayland_time() + 5000, .next = clip.sends });
			clip.sends = transfer;
			clip.send_count++;
		}
		else if (opcode == 2) // cancelled
		{
			*link = source.next;
			self.destroy_request(source.proxy, 1);
			source.text.free(mem);
			mem::free(source);
		}
		return;
	}
}
