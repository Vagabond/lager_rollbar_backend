Lager Rollbar backend
---------------------

This is a lager backend for sending messages to rollbar. You can use it like this

```
{lager_rollbar_backend, [{api_key, <<"xxxxxxxxxxx">>}, {level, error}, {environment, staging}]
```

You can omit the 'environment'.

That's about it for now.
