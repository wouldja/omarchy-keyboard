// SPDX-License-Identifier: GPL-2.0
/*
 * Keyboard backlight for the Clevo P870DM-G (Sager).
 *
 * Three keyboard zones plus the front light bar, through the Clevo WMI
 * method used by clevo-xsm-wmi. Colors are full RGB. Effects are the
 * firmware patterns.
 */

#include <linux/acpi.h>
#include <linux/dmi.h>
#include <linux/kernel.h>
#include <linux/kthread.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/platform_device.h>
#include <linux/string.h>
#include <linux/sysfs.h>
#include <linux/suspend.h>
#include <linux/wmi.h>

#define SAGER_WMI_GUID "ABBC0F6D-8EA1-11D1-00A0-C90629100000"
#define SAGER_SET_KB 0x67
#define SAGER_SET_FAN 0x68
#define SAGER_FAN_AUTO 0x69
#define SAGER_SET_PROFILE 0x79
#define SAGER_PROFILE_SUB 0x19

#define SAGER_PROFILE_QUIET 0
#define SAGER_PROFILE_BALANCED 1
#define SAGER_PROFILE_PERFORMANCE 2

#define SAGER_EC_CPU_TEMP 0x07
#define SAGER_EC_GPU_TEMP 0xcd
#define SAGER_EC_FAN_DUTY 0xce
#define SAGER_EC_FAN_RPM 0xd0

#define SAGER_CURVE_POINTS 5
#define SAGER_FAN_FLOOR 25

#define SAGER_KB_ON 0xE007F001
#define SAGER_KB_OFF 0xE0003001
#define SAGER_MODE_PREFIX 0x10000000
#define SAGER_BRIGHTNESS 0xF4000000

#define SAGER_ZONE_LEFT 0xF0000000
#define SAGER_ZONE_CENTER 0xF1000000
#define SAGER_ZONE_RIGHT 0xF2000000
#define SAGER_ZONE_LIGHTBAR 0xF3000000

struct sager_rgb {
	u8 r, g, b;
};

struct sager_mode {
	const char *name;
	u32 cmd;
};

static const struct sager_mode sager_modes[] = {
	{ "static", 0 },
	{ "breathe", 0x1002a000 },
	{ "cycle", 0x33010000 },
	{ "dance", 0x80000000 },
	{ "flash", 0xA0000000 },
	{ "random", 0x70000000 },
	{ "tempo", 0x90000000 },
	{ "wave", 0xB0000000 },
};

static struct sager_state {
	struct mutex lock;
	struct sager_rgb zone[4];
	u8 brightness;
	unsigned int mode;
	bool enabled;
	bool hw_on;
	bool applied;
} st = {
	.zone = {
		{ 255, 255, 255 },
		{ 255, 255, 255 },
		{ 255, 255, 255 },
		{ 255, 255, 255 },
	},
	.brightness = 255,
	.mode = 0,
	.enabled = true,
};

static struct platform_device *sager_pdev;
static struct notifier_block sager_pm_nb;

static const u32 sager_zone_code[] = {
	SAGER_ZONE_LEFT,
	SAGER_ZONE_CENTER,
	SAGER_ZONE_RIGHT,
	SAGER_ZONE_LIGHTBAR,
};

static int sager_wmi(u8 method, u32 arg, u32 *out)
{
	struct acpi_buffer in = { (acpi_size)sizeof(arg), &arg };
	struct acpi_buffer output = { ACPI_ALLOCATE_BUFFER, NULL };
	union acpi_object *obj;
	acpi_status status;

	status = wmi_evaluate_method(SAGER_WMI_GUID, 0, method, &in, &output);
	if (ACPI_FAILURE(status)) {
		ACPI_FREE(output.pointer);
		pr_err_ratelimited("command 0x%02x arg 0x%08x failed\n", method, arg);
		return -EIO;
	}
	obj = output.pointer;
	if (out) {
		if (obj && obj->type == ACPI_TYPE_INTEGER)
			*out = (u32)obj->integer.value;
		else
			*out = 0;
	}
	ACPI_FREE(obj);
	return 0;
}

static int sager_call(u32 arg)
{
	return sager_wmi(SAGER_SET_KB, arg, NULL);
}

static u32 sager_color_arg(u32 zone, struct sager_rgb color)
{
	/* EC byte order is B, R, G under the zone selector. */
	return zone | ((u32)color.b << 16) | ((u32)color.r << 8) | color.g;
}

static int sager_hw_sync(bool force_on)
{
	int i, err = 0;
	const struct sager_mode *mode = &sager_modes[st.mode];

	if (!st.enabled) {
		err = sager_call(SAGER_KB_OFF);
		st.hw_on = false;
		return err;
	}

	if (force_on || !st.hw_on) {
		err = sager_call(SAGER_KB_ON);
		if (err)
			return err;
		st.hw_on = true;
	}

	if (mode->cmd == 0) {
		for (i = 0; i < 4; i++) {
			err = sager_call(sager_color_arg(sager_zone_code[i], st.zone[i]));
			if (err)
				return err;
		}
	} else {
		err = sager_call(SAGER_MODE_PREFIX);
		if (err)
			return err;
		err = sager_call(mode->cmd);
		if (err)
			return err;
	}

	err = sager_call(SAGER_BRIGHTNESS | st.brightness);
	if (!err)
		st.applied = true;
	return err;
}

enum sager_fan_mode {
	SAGER_FANS_AUTO = 0,
	SAGER_FANS_QUIET,
	SAGER_FANS_PERFORMANCE,
	SAGER_FANS_CURVE,
	SAGER_FANS_MANUAL,
};

struct sager_point {
	u8 temp;
	u8 duty;
};

static const struct sager_point sager_quiet_curve[SAGER_CURVE_POINTS] = {
	{ 45, 0 }, { 60, 30 }, { 72, 45 }, { 82, 70 }, { 92, 100 },
};

static const struct sager_point sager_perf_curve[SAGER_CURVE_POINTS] = {
	{ 40, 45 }, { 55, 65 }, { 68, 85 }, { 78, 100 }, { 90, 100 },
};

static const struct sager_point sager_custom_curve[SAGER_CURVE_POINTS] = {
	{ 45, 25 }, { 60, 45 }, { 72, 65 }, { 82, 85 }, { 92, 100 },
};

static const char * const sager_fan_mode_names[] = {
	"auto", "quiet", "performance", "curve", "manual",
};

static struct sager_fans {
	enum sager_fan_mode mode;
	u8 manual_duty;
	u8 applied_duty;
	bool taken;
	bool profile_owned;
	struct sager_point curve[SAGER_CURVE_POINTS];
	struct task_struct *task;
} fans;

static int sager_fan_apply_locked(void);

static int sager_pm_notify(struct notifier_block *nb, unsigned long action, void *unused)
{
	if (action != PM_POST_SUSPEND && action != PM_POST_HIBERNATION)
		return NOTIFY_DONE;

	mutex_lock(&st.lock);
	if (st.applied) {
		st.hw_on = false;
		sager_hw_sync(true);
	}
	sager_fan_apply_locked();
	mutex_unlock(&st.lock);
	return NOTIFY_OK;
}

static int sager_sensor(u8 addr)
{
	u8 value;

	if (ec_read(addr, &value))
		return -1;
	if (value == 0 || value > 125)
		return -1;
	return value;
}

static int sager_rpm(int index)
{
	u8 hi = 0, lo = 0;
	unsigned int raw;

	if (ec_read(SAGER_EC_FAN_RPM + 2 * index, &hi))
		return -1;
	if (ec_read(SAGER_EC_FAN_RPM + 2 * index + 1, &lo))
		return -1;
	raw = ((unsigned int)hi << 8) | lo;
	if (raw < 0x20 || raw > 0xf000)
		return 0;
	return 2156220 / (int)raw;
}

static int sager_hw_duty(void)
{
	u8 raw;

	if (ec_read(SAGER_EC_FAN_DUTY, &raw))
		return -1;
	return (raw * 100) / 255;
}

/* The EC ignores duty values between off and about 25 percent. */
static u8 sager_duty_raw(unsigned int percent)
{
	unsigned int raw;

	if (percent == 0)
		return 0;
	if (percent > 100)
		percent = 100;
	raw = (percent * 255) / 100;
	if (raw < (SAGER_FAN_FLOOR * 255) / 100)
		raw = (SAGER_FAN_FLOOR * 255) / 100;
	if (raw > 255)
		raw = 255;
	return raw;
}

static int sager_fans_write(unsigned int percent)
{
	u8 raw = sager_duty_raw(percent);
	u32 arg = raw | ((u32)raw << 8) | ((u32)raw << 16);

	return sager_wmi(SAGER_SET_FAN, arg, NULL);
}

static void sager_try_profile(u8 profile)
{
	u32 arg = ((u32)SAGER_PROFILE_SUB << 24) | profile;

	if (sager_wmi(SAGER_SET_PROFILE, arg, NULL))
		pr_debug("performance profile %u was not accepted\n", profile);
}

static unsigned int sager_curve_duty(const struct sager_point *points, int temp)
{
	int i;

	if (temp >= 95)
		return 100;
	if (temp <= points[0].temp)
		return points[0].duty;
	for (i = 1; i < SAGER_CURVE_POINTS; i++) {
		int span, rise;

		if (temp > points[i].temp)
			continue;
		span = points[i].temp - points[i - 1].temp;
		rise = (int)points[i].duty - (int)points[i - 1].duty;
		if (span <= 0)
			return points[i].duty;
		return points[i - 1].duty + (temp - points[i - 1].temp) * rise / span;
	}
	return points[SAGER_CURVE_POINTS - 1].duty;
}

static int sager_hottest(void)
{
	int cpu = sager_sensor(SAGER_EC_CPU_TEMP);
	int gpu = sager_sensor(SAGER_EC_GPU_TEMP);

	if (cpu < 0 && gpu < 0)
		return -1;
	if (gpu > cpu)
		return gpu;
	return cpu;
}

static int sager_fan_apply_locked(void)
{
	const struct sager_point *curve;
	int temp, duty, err;

	if (fans.mode == SAGER_FANS_AUTO) {
		err = sager_wmi(SAGER_FAN_AUTO, 0, NULL);
		if (!err)
			fans.taken = false;
		if (fans.profile_owned) {
			sager_try_profile(SAGER_PROFILE_BALANCED);
			fans.profile_owned = false;
		}
		return err;
	}

	if (fans.mode == SAGER_FANS_QUIET) {
		sager_try_profile(SAGER_PROFILE_QUIET);
		fans.profile_owned = true;
		curve = sager_quiet_curve;
	} else if (fans.mode == SAGER_FANS_PERFORMANCE) {
		sager_try_profile(SAGER_PROFILE_PERFORMANCE);
		fans.profile_owned = true;
		curve = sager_perf_curve;
	} else if (fans.mode == SAGER_FANS_MANUAL) {
		err = sager_fans_write(fans.manual_duty);
		if (!err) {
			fans.taken = true;
			fans.applied_duty = fans.manual_duty;
		}
		return err;
	} else {
		curve = fans.curve;
	}

	temp = sager_hottest();
	if (temp < 0) {
		err = sager_fans_write(100);
		if (!err) {
			fans.taken = true;
			fans.applied_duty = 100;
		}
		return err;
	}

	duty = sager_curve_duty(curve, temp);
	err = sager_fans_write(duty);
	if (!err) {
		fans.taken = true;
		fans.applied_duty = duty;
	}
	return err;
}

static int sager_fan_thread(void *unused)
{
	while (!kthread_should_stop()) {
		mutex_lock(&st.lock);
		if (fans.mode == SAGER_FANS_QUIET ||
		    fans.mode == SAGER_FANS_PERFORMANCE ||
		    fans.mode == SAGER_FANS_CURVE)
			sager_fan_apply_locked();
		mutex_unlock(&st.lock);
		if (kthread_should_stop())
			break;
		schedule_timeout_interruptible(2 * HZ);
	}
	return 0;
}

static int sager_fan_mode_index(const char *buf)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(sager_fan_mode_names); i++) {
		if (sysfs_streq(buf, sager_fan_mode_names[i]))
			return i;
	}
	return -EINVAL;
}

static ssize_t fan_mode_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	const char *name;

	mutex_lock(&st.lock);
	name = sager_fan_mode_names[fans.mode];
	mutex_unlock(&st.lock);
	return sysfs_emit(buf, "%s\n", name);
}

static ssize_t fan_mode_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	int index, err;

	index = sager_fan_mode_index(buf);
	if (index < 0)
		return index;
	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	fans.mode = index;
	err = sager_fan_apply_locked();
	mutex_unlock(&st.lock);
	return err ? err : count;
}

static struct device_attribute dev_attr_fan_mode = __ATTR(fan_mode, 0644, fan_mode_show, fan_mode_store);

static ssize_t fan_duty_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int value;

	mutex_lock(&st.lock);
	if (fans.mode == SAGER_FANS_MANUAL)
		value = fans.manual_duty;
	else if (fans.mode == SAGER_FANS_AUTO)
		value = sager_hw_duty();
	else
		value = fans.applied_duty;
	mutex_unlock(&st.lock);
	if (value < 0)
		value = 0;
	return sysfs_emit(buf, "%d\n", value);
}

static ssize_t fan_duty_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	unsigned int value;
	int err = 0;

	err = kstrtouint(buf, 0, &value);
	if (err)
		return err;
	if (value > 100)
		return -EINVAL;
	if (value > 0 && value < SAGER_FAN_FLOOR)
		value = SAGER_FAN_FLOOR;
	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	fans.manual_duty = value;
	if (fans.mode == SAGER_FANS_MANUAL)
		err = sager_fan_apply_locked();
	mutex_unlock(&st.lock);
	return err ? err : count;
}

static struct device_attribute dev_attr_fan_duty = __ATTR(fan_duty, 0644, fan_duty_show, fan_duty_store);

static ssize_t fan_curve_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	ssize_t len = 0;
	int i;

	mutex_lock(&st.lock);
	for (i = 0; i < SAGER_CURVE_POINTS; i++) {
		len += sysfs_emit_at(buf, len, "%s%u:%u", i ? " " : "",
				     fans.curve[i].temp, fans.curve[i].duty);
	}
	mutex_unlock(&st.lock);
	len += sysfs_emit_at(buf, len, "\n");
	return len;
}

static ssize_t fan_curve_store(struct device *dev, struct device_attribute *attr,
			      const char *buf, size_t count)
{
	struct sager_point next[SAGER_CURVE_POINTS];
	unsigned int temp, duty;
	int consumed = 0, i, err = 0;
	const char *cursor = buf;

	for (i = 0; i < SAGER_CURVE_POINTS; i++) {
		if (sscanf(cursor, "%u:%u%n", &temp, &duty, &consumed) != 2)
			return -EINVAL;
		if (temp < 20 || temp > 100 || duty > 100)
			return -EINVAL;
		if (i > 0 && temp <= next[i - 1].temp)
			return -EINVAL;
		next[i].temp = temp;
		next[i].duty = duty;
		cursor += consumed;
		while (*cursor == ' ')
			cursor++;
	}
	if (*cursor != '\0' && *cursor != '\n')
		return -EINVAL;

	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	memcpy(fans.curve, next, sizeof(next));
	if (fans.mode == SAGER_FANS_CURVE)
		err = sager_fan_apply_locked();
	mutex_unlock(&st.lock);
	return err ? err : count;
}

static struct device_attribute dev_attr_fan_curve = __ATTR(fan_curve, 0644, fan_curve_show, fan_curve_store);

static ssize_t cpu_temp_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int value = sager_sensor(SAGER_EC_CPU_TEMP);

	return sysfs_emit(buf, "%d\n", value < 0 ? 0 : value);
}

static ssize_t gpu_temp_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int value = sager_sensor(SAGER_EC_GPU_TEMP);

	return sysfs_emit(buf, "%d\n", value < 0 ? 0 : value);
}

static ssize_t cpu_rpm_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int value = sager_rpm(0);

	return sysfs_emit(buf, "%d\n", value < 0 ? 0 : value);
}

static ssize_t gpu_rpm_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	int value = sager_rpm(1);

	return sysfs_emit(buf, "%d\n", value < 0 ? 0 : value);
}

static struct device_attribute dev_attr_cpu_temp = __ATTR(cpu_temp, 0444, cpu_temp_show, NULL);
static struct device_attribute dev_attr_gpu_temp = __ATTR(gpu_temp, 0444, gpu_temp_show, NULL);
static struct device_attribute dev_attr_cpu_rpm = __ATTR(cpu_rpm, 0444, cpu_rpm_show, NULL);
static struct device_attribute dev_attr_gpu_rpm = __ATTR(gpu_rpm, 0444, gpu_rpm_show, NULL);

static ssize_t fan_state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	ssize_t len = 0;
	int i, cpu, gpu, cpu_rpm, gpu_rpm, hw;

	mutex_lock(&st.lock);
	cpu = sager_sensor(SAGER_EC_CPU_TEMP);
	gpu = sager_sensor(SAGER_EC_GPU_TEMP);
	cpu_rpm = sager_rpm(0);
	gpu_rpm = sager_rpm(1);
	hw = sager_hw_duty();
	len += sysfs_emit_at(buf, len, "mode=%s\n", sager_fan_mode_names[fans.mode]);
	len += sysfs_emit_at(buf, len, "duty=%u\n",
			     fans.mode == SAGER_FANS_MANUAL ? fans.manual_duty : fans.applied_duty);
	len += sysfs_emit_at(buf, len, "manual=%u\n", fans.manual_duty);
	len += sysfs_emit_at(buf, len, "hw_duty=%d\n", hw < 0 ? 0 : hw);
	len += sysfs_emit_at(buf, len, "cpu_temp=%d\n", cpu < 0 ? 0 : cpu);
	len += sysfs_emit_at(buf, len, "gpu_temp=%d\n", gpu < 0 ? 0 : gpu);
	len += sysfs_emit_at(buf, len, "cpu_rpm=%d\n", cpu_rpm < 0 ? 0 : cpu_rpm);
	len += sysfs_emit_at(buf, len, "gpu_rpm=%d\n", gpu_rpm < 0 ? 0 : gpu_rpm);
	len += sysfs_emit_at(buf, len, "curve=");
	for (i = 0; i < SAGER_CURVE_POINTS; i++) {
		len += sysfs_emit_at(buf, len, "%s%u:%u", i ? " " : "",
				     fans.curve[i].temp, fans.curve[i].duty);
	}
	len += sysfs_emit_at(buf, len, "\n");
	mutex_unlock(&st.lock);
	return len;
}

static struct device_attribute dev_attr_fan_state = __ATTR(fan_state, 0444, fan_state_show, NULL);

static ssize_t sager_zone_show(int index, char *buf)
{
	struct sager_rgb color;

	mutex_lock(&st.lock);
	color = st.zone[index];
	mutex_unlock(&st.lock);
	return sysfs_emit(buf, "%u %u %u\n", color.r, color.g, color.b);
}

static int sager_parse_rgb(const char *buf, struct sager_rgb *color)
{
	unsigned int r, g, b;
	char tmp[32];
	int n;

	n = sscanf(buf, "%u %u %u", &r, &g, &b);
	if (n == 3)
		goto check;

	if (buf[0] == '#')
		buf++;
	n = sscanf(buf, "%2x%2x%2x", &r, &g, &b);
	if (n != 3) {
		/* Accept the names the firmware keys cycle through. */
		if (sscanf(buf, "%31s", tmp) != 1)
			return -EINVAL;
		if (!strcmp(tmp, "off") || !strcmp(tmp, "black")) {
			*color = (struct sager_rgb){};
			return 0;
		}
		if (!strcmp(tmp, "red"))
			r = 255, g = 0, b = 0;
		else if (!strcmp(tmp, "green"))
			r = 0, g = 255, b = 0;
		else if (!strcmp(tmp, "blue"))
			r = 0, g = 0, b = 255;
		else if (!strcmp(tmp, "yellow"))
			r = 255, g = 255, b = 0;
		else if (!strcmp(tmp, "magenta"))
			r = 255, g = 0, b = 255;
		else if (!strcmp(tmp, "cyan"))
			r = 0, g = 255, b = 255;
		else if (!strcmp(tmp, "white"))
			r = 255, g = 255, b = 255;
		else
			return -EINVAL;
	}

check:
	if (r > 255 || g > 255 || b > 255)
		return -EINVAL;
	color->r = r;
	color->g = g;
	color->b = b;
	return 0;
}

static ssize_t sager_zone_store(int index, const char *buf, size_t count)
{
	struct sager_rgb color;
	int err;

	err = sager_parse_rgb(buf, &color);
	if (err)
		return err;
	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	st.zone[index] = color;
	/* A direct color write leaves an effect and returns to a solid color. */
	st.mode = 0;
	mutex_unlock(&st.lock);
	return count;
}

#define SAGER_ZONE_ATTR(attr, idx)								\
static ssize_t attr##_show(struct device *dev, struct device_attribute *a, char *buf)		\
{												\
	return sager_zone_show(idx, buf);							\
}												\
static ssize_t attr##_store(struct device *dev, struct device_attribute *a,			\
			    const char *buf, size_t count)					\
{												\
	return sager_zone_store(idx, buf, count);						\
}												\
static struct device_attribute dev_attr_##attr = __ATTR(attr, 0644, attr##_show, attr##_store)

SAGER_ZONE_ATTR(left, 0);
SAGER_ZONE_ATTR(center, 1);
SAGER_ZONE_ATTR(right, 2);
SAGER_ZONE_ATTR(lightbar, 3);

static ssize_t brightness_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	unsigned int value;

	mutex_lock(&st.lock);
	value = st.brightness;
	mutex_unlock(&st.lock);
	return sysfs_emit(buf, "%u\n", value);
}

static ssize_t brightness_store(struct device *dev, struct device_attribute *attr,
				const char *buf, size_t count)
{
	unsigned int value;
	int err;

	err = kstrtouint(buf, 0, &value);
	if (err)
		return err;
	if (value > 255)
		return -EINVAL;
	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	st.brightness = value;
	mutex_unlock(&st.lock);
	return count;
}

static struct device_attribute dev_attr_brightness = __ATTR(brightness, 0644, brightness_show, brightness_store);

static ssize_t enabled_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	unsigned int value;

	mutex_lock(&st.lock);
	value = st.enabled ? 1 : 0;
	mutex_unlock(&st.lock);
	return sysfs_emit(buf, "%u\n", value);
}

static bool sager_truthy(const char *buf)
{
	return sysfs_streq(buf, "1") || sysfs_streq(buf, "on") || sysfs_streq(buf, "true");
}

static bool sager_falsey(const char *buf)
{
	return sysfs_streq(buf, "0") || sysfs_streq(buf, "off") || sysfs_streq(buf, "false");
}

static ssize_t enabled_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	bool enabled;

	if (sager_truthy(buf))
		enabled = true;
	else if (sager_falsey(buf))
		enabled = false;
	else
		return -EINVAL;
	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	st.enabled = enabled;
	mutex_unlock(&st.lock);
	return count;
}

static struct device_attribute dev_attr_enabled = __ATTR(enabled, 0644, enabled_show, enabled_store);

static ssize_t mode_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	const char *name;

	mutex_lock(&st.lock);
	name = sager_modes[st.mode].name;
	mutex_unlock(&st.lock);
	return sysfs_emit(buf, "%s\n", name);
}

static int sager_mode_index(const char *buf)
{
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(sager_modes); i++) {
		if (sysfs_streq(buf, sager_modes[i].name))
			return i;
	}
	return -EINVAL;
}

static ssize_t mode_store(struct device *dev, struct device_attribute *attr,
			  const char *buf, size_t count)
{
	int index;

	index = sager_mode_index(buf);
	if (index < 0)
		return index;
	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	st.mode = index;
	mutex_unlock(&st.lock);
	return count;
}

static struct device_attribute dev_attr_mode = __ATTR(mode, 0644, mode_show, mode_store);

static ssize_t apply_store(struct device *dev, struct device_attribute *attr,
			   const char *buf, size_t count)
{
	int err;

	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	err = sager_hw_sync(false);
	mutex_unlock(&st.lock);
	return err ? err : count;
}

static struct device_attribute dev_attr_apply = __ATTR(apply, 0200, NULL, apply_store);

static ssize_t state_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	ssize_t len = 0;
	int i;
	static const char *names[] = { "left", "center", "right", "lightbar" };

	if (mutex_lock_interruptible(&st.lock))
		return -ERESTARTSYS;
	len += sysfs_emit_at(buf, len, "enabled=%u\n", st.enabled ? 1 : 0);
	len += sysfs_emit_at(buf, len, "brightness=%u\n", st.brightness);
	len += sysfs_emit_at(buf, len, "mode=%s\n", sager_modes[st.mode].name);
	for (i = 0; i < 4; i++) {
		len += sysfs_emit_at(buf, len, "%s=%u %u %u\n", names[i],
				     st.zone[i].r, st.zone[i].g, st.zone[i].b);
	}
	mutex_unlock(&st.lock);
	return len;
}

static struct device_attribute dev_attr_state = __ATTR(state, 0444, state_show, NULL);

static struct attribute *sager_attrs[] = {
	&dev_attr_left.attr,
	&dev_attr_center.attr,
	&dev_attr_right.attr,
	&dev_attr_lightbar.attr,
	&dev_attr_brightness.attr,
	&dev_attr_enabled.attr,
	&dev_attr_mode.attr,
	&dev_attr_apply.attr,
	&dev_attr_state.attr,
	&dev_attr_fan_mode.attr,
	&dev_attr_fan_duty.attr,
	&dev_attr_fan_curve.attr,
	&dev_attr_fan_state.attr,
	&dev_attr_cpu_temp.attr,
	&dev_attr_gpu_temp.attr,
	&dev_attr_cpu_rpm.attr,
	&dev_attr_gpu_rpm.attr,
	NULL,
};

static const struct attribute_group sager_group = {
	.attrs = sager_attrs,
};

/* The desktop session writes these files. Sysfs rejects a world-writable
 * mode at compile time, so the files are created root-only and opened here.
 */
static void sager_relax_permissions(void)
{
	static const char *names[] = {
		"left", "center", "right", "lightbar",
		"brightness", "enabled", "mode", "apply",
		"fan_mode", "fan_duty", "fan_curve",
	};
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(names); i++) {
		struct attribute attr = { .name = names[i] };

		if (sysfs_chmod_file(&sager_pdev->dev.kobj, &attr, 0666))
			pr_warn("could not open %s for the session\n", names[i]);
	}
}

static bool sager_is_p870(void)
{
	const char *product = dmi_get_system_info(DMI_PRODUCT_NAME);
	const char *board = dmi_get_system_info(DMI_BOARD_NAME);

	return (product && strstr(product, "P870DM")) || (board && strstr(board, "P870DM"));
}

static int sager_probe(struct wmi_device *wdev, const void *context)
{
	int err;

	if (!sager_is_p870())
		return -ENODEV;
	if (!wmi_has_guid(SAGER_WMI_GUID))
		return -ENODEV;

	mutex_init(&st.lock);
	memcpy(fans.curve, sager_custom_curve, sizeof(fans.curve));
	fans.manual_duty = 40;
	fans.mode = SAGER_FANS_AUTO;
	sager_pdev = platform_device_register_simple("sager_kbd", PLATFORM_DEVID_NONE, NULL, 0);
	if (IS_ERR(sager_pdev))
		return PTR_ERR(sager_pdev);

	err = sysfs_create_group(&sager_pdev->dev.kobj, &sager_group);
	if (err) {
		platform_device_unregister(sager_pdev);
		sager_pdev = NULL;
		return err;
	}
	sager_relax_permissions();

	sager_pm_nb.notifier_call = sager_pm_notify;
	register_pm_notifier(&sager_pm_nb);
	fans.task = kthread_run(sager_fan_thread, NULL, "sager-fans");
	if (IS_ERR(fans.task)) {
		pr_warn("fan controller did not start\n");
		fans.task = NULL;
	}
	pr_info("P870DM keyboard backlight and fans ready\n");
	return 0;
}

static void sager_remove(struct wmi_device *wdev)
{
	unregister_pm_notifier(&sager_pm_nb);
	if (fans.task) {
		kthread_stop(fans.task);
		fans.task = NULL;
	}
	if (sager_pdev)
		sysfs_remove_group(&sager_pdev->dev.kobj, &sager_group);
	mutex_lock(&st.lock);
	if (fans.taken)
		sager_wmi(SAGER_FAN_AUTO, 0, NULL);
	if (fans.profile_owned)
		sager_try_profile(SAGER_PROFILE_BALANCED);
	fans.taken = false;
	fans.profile_owned = false;
	fans.mode = SAGER_FANS_AUTO;
	mutex_unlock(&st.lock);
	if (sager_pdev) {
		platform_device_unregister(sager_pdev);
		sager_pdev = NULL;
	}
}

static const struct wmi_device_id sager_id_table[] = {
	{ .guid_string = SAGER_WMI_GUID },
	{ }
};
MODULE_DEVICE_TABLE(wmi, sager_id_table);

static struct wmi_driver sager_wmi_driver = {
	.driver = {
		.name = "sager_kbd",
	},
	.id_table = sager_id_table,
	.probe = sager_probe,
	.remove = sager_remove,
};

static int __init sager_init(void)
{
	if (!sager_is_p870())
		return -ENODEV;
	return wmi_driver_register(&sager_wmi_driver);
}

static void __exit sager_exit(void)
{
	wmi_driver_unregister(&sager_wmi_driver);
}

module_init(sager_init);
module_exit(sager_exit);

MODULE_AUTHOR("Brian Ehlers");
MODULE_DESCRIPTION("Clevo P870DM-G keyboard backlight and fan control");
MODULE_LICENSE("GPL");
MODULE_ALIAS("wmi:" SAGER_WMI_GUID);
