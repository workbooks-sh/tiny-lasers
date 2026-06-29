// dayjs-1.11.10 feature cases — date/time parse + arithmetic + format. `module.exports` is the dayjs
// function. Cases are timezone-stable (date arithmetic + component reads on the same host as the oracle).
const d = module.exports;
function show(label, v) { console.log(label + "=" + String(v)); }
show("fmt", d("2019-01-25").format("YYYY-MM-DD"));
show("addDay", d("2019-01-25").add(1, "day").format("YYYY-MM-DD"));
show("addMonth", d("2019-01-25").add(2, "month").format("YYYY-MM-DD"));
show("subMonth", d("2019-01-25").subtract(1, "month").format("YYYY-MM-DD"));
show("diffDay", d("2019-01-25").diff(d("2019-01-20"), "day"));
show("dayOfWeek", d("2019-01-25").day());                       // Friday = 5
show("year", d("2019-01-25").year());
show("month", d("2019-01-25").month());                        // 0-indexed → 0
show("date", d("2019-01-25").date());
show("time", d("2019-01-25T12:30:45").format("HH:mm:ss"));
show("startOfMonth", d("2019-01-25").startOf("month").format("YYYY-MM-DD"));
show("endOfMonth", d("2019-01-25").endOf("month").format("YYYY-MM-DD"));
show("isBefore", d("2019-01-20").isBefore(d("2019-01-25")));
show("unixSet", d("2019-01-25").add(1, "year").format("YYYY"));
