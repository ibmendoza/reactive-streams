use "collections"

class SubscriberManager[A: Any tag]
  """
  Manages a subscriber list.
  """
  let _pub: ManagedPublisher[A]
  let _map: MapIs[Subscriber[A], _SubscriberState] = _map.create()
  let _queue: List[A] = _queue.create()
  let _qbound: U64
  var _min_request: U64 = 0
  var _max_request: U64 = 0

  new create(pub: ManagedPublisher[A], qbound: U64 = U64.max_value()) =>
    """
    Create a SubscriberManager for a given ManagedPublisher.
    """
    _pub = pub
    _qbound = if qbound == 0 then 1 else qbound end

  fun min_request(): U64 =>
    """
    Returns the lowest request count of all subscribers.
    """
    _min_request

  fun max_request(): U64 =>
    """
    Returns the highest request count of all subscribers.
    """
    _max_request

  fun queue_bound(): U64 =>
    """
    Returns the queue bound.
    """
    _qbound

  fun queue_size(): U64 =>
    """
    Returns the current queue size.
    """
    _queue.size()

  fun subscriber_count(): U64 =>
    """
    Returns the current subscriber count.
    """
    _map.size()

  fun ref push(a: A) =>
    """
    TODO: send to one subscriber instead of all.
    """

  fun ref publish(a: A) =>
    """
    A ManagedPublisher should call this when it has data to publish.
    Subscribers with pending demand will be sent the data immediately. If any
    subscribers with no pending demand exist, the data will be kept on a
    queue to be sent when subscribers request additional data.

    The queue size can be bounded. If so, undelivered old data will be dropped
    if new data must be queued and the queue has hit its size limit.
    """
    if _map.size() == 0 then
      // Drop if we have no subscribers.
      return
    end

    if _min_request > 0 then
      // All subscribers have pending demand. Send the new data to them all,
      // reducing each one's request count. Also reduce _min_request.
      _min_request = _min_request - 1
      _max_request = _max_request - 1

      for (sub, state) in _map.pairs() do
        state.request = state.request - 1
        sub.on_next(a)
      end

      return
    end

    if _queue.size() == _qbound then
      // We have hit our bound and must drop from the queue.
      try
        _queue.shift()
        _queue.push(a)

        for (sub, state) in _map.pairs() do
          if state.request > 0 then
            // The subscriber has pending demand. Leave the queue_position
            // where it is, but reduce the request count.
            state.request = state.request - 1
            sub.on_next(a)
          else
            // The subscriber has no pending demand. Since we dropped from the
            // queue, move the queue_position back one.
            if state.queue_position > 0 then
              state.queue_position = state.queue_position - 1
            end
          end
        end

        return
      end
    end

    // We aren't at the queue bound.
    _queue.push(a)
    let pos = _queue.size()

    for (sub, state) in _map.pairs() do
      if state.request > 0 then
        // The subscriber has pending demand. Move the queue_position to the
        // current tail, and reduce the request count.
        state.request = state.request - 1
        state.queue_position = pos
        sub.on_next(a)
      end
    end

  fun ref on_complete() =>
    """
    A ManagedPublisher should call this when it has no more data to produce.
    """
    for sub in _map.keys() do
      sub.on_complete()
    end
    _reset()

  fun ref on_error() =>
    """
    A ManagedPublisher should call this when its internal state has resulted in
    an error that should be propagated to all subscribers.
    """
    for sub in _map.keys() do
      sub.on_error()
    end
    _reset()

  fun ref _reset() =>
    """
    Reset after completion or error.
    """
    _map.clear()
    _queue.clear()
    _min_request = 0
    _max_request = 0

  fun ref _on_subscribe(sub: Subscriber[A]) =>
    """
    A ManagedPublisher should call this when it receives Publisher.subscribe.
    """
    let prev = _map(sub) = _SubscriberState

    if prev isnt None then
      // TODO: let the subscriber know they have double subscribed
      sub.on_error()
    end

    sub.on_subscribe(_Subscription[A](sub, _pub))
    _min_request = 0

  fun ref _on_request(sub: Subscriber[A], n: U64) =>
    """
    A ManagedPublisher should call this when it receives
    ManagedPublisher._on_request.
    """
    try
      let state = _map(sub)
      var inc = n

      if (state.request == 0) and (state.queue_position < _queue.size()) then
        try
          // Send pending backlog.
          var count = inc.min(_queue.size() - state.queue_position)
          var node = _queue.index(state.queue_position)

          for i in Range(0, count) do
            sub.on_next(node())

            if node.has_next() then
              node = node.next() as ListNode[A]
            end
          end

          let adjust = state.queue_position == 0
          state.queue_position = state.queue_position + count
          inc = inc - count

          // Possibly djust the queue if we were blocking the head.
          if adjust then
            _adjust_queue()
          end
        end
      end

      if inc > 0 then
        let recalc = state.request == _min_request

        if (state.request + inc) < state.request then
          state.request = U64.max_value()
        else
          state.request = state.request + inc
        end

        _max_request = _max_request.max(state.request)
        if recalc then _find_min_request() end
      end
    end

  fun ref _on_cancel(sub: Subscriber[A]) =>
    """
    A ManagedPublisher should call this when it receives
    ManagedPublisher._on_cancel.
    """
    try
      (_, let state) = _map.remove(sub)

      if
        (state.request == 0) and
        (state.queue_position == 0) and
        (_queue.size() > 0)
      then
        // If this subscriber was blocking at the head of the queue, we may be
        // able to adjust the queue.
        _adjust_queue()
      end
    end

  fun ref _find_min_request() =>
    """
    Recalculate the _min_request value.
    """
    _min_request = U64.max_value()

    for state in _map.values() do
      _min_request = _min_request.min(state.request)
    end

  fun ref _adjust_queue() =>
    """
    When a subscriber is removed or gets sent backlog data, call this to drop
    elements from the queue that are no longer needed.
    """
    var min_queue_position = U64.max_value()

    for state in _map.values() do
      min_queue_position = min_queue_position.min(state.queue_position)
    end

    if min_queue_position > 0 then
      try
        for i in Range(0, min_queue_position) do
          _queue.shift()
        end
      end

      for state in _map.values() do
        state.queue_position = state.queue_position - min_queue_position
      end
    end

class _SubscriberState
  """
  Keeps track of the pending demand and queue position for a subscriber.
  """
  var request: U64 = 0
  var queue_position: U64 = 0

class _Subscription[A: Any tag] iso is Subscription
  """
  Implements Subscription[A], allowing a subscriber to a ManagedPublisher to
  request more data or cancel its subscription.
  """
  let _sub: Subscriber[A]
  let _pub: ManagedPublisher[A]
  var _cancelled: Bool = false

  new iso create(sub: Subscriber[A], pub: ManagedPublisher[A]) =>
    """
    Create a _Subscription for a given subscriber and publisher.
    """
    _sub = sub
    _pub = pub

  fun ref request(n: U64) =>
    """
    Request more data. NOP if the subscription has been cancelled.
    """
    if not _cancelled and (n > 0) then
      _pub._on_request(_sub, n)
    end

  fun ref cancel() =>
    """
    Cancel the subscription. NOP if it has already been cancelled.
    """
    if not _cancelled then
      _cancelled = true
      _pub._on_cancel(_sub)
    end