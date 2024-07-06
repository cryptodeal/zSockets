// TODO: avoid relying on c types
pub const InternalLoopData = struct {
    // struct us_timer_t *sweep_timer;
    // struct us_internal_async *wakeup_async;
    last_write_failed: c_int,
    // struct us_socket_context_t *head;
    // struct us_socket_context_t *iterator;
    recv_buf: []u8,
    ssl_data: ?*anyopaque,
    // void (*pre_cb)(struct us_loop_t *);
    // void (*post_cb)(struct us_loop_t *);
    // struct us_socket_t *closed_head;
    // struct us_socket_t *low_prio_head;
    low_prio_budget: c_int,
    //  We do not care if this flips or not, it doesn't matter
    iteration_nr: c_longlong,
};
