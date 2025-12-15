import csv
import random
import math
from datetime import datetime, timedelta

# Configuration
NUM_SENSORS = 20
START_DATE = datetime.now() - timedelta(days=60)  # 2 months ago
END_DATE = datetime.now()
INTERVAL_MINUTES = 1

# Generate sensor metadata
def generate_sensor_metadata():
    """Generate sensors.csv with metadata for each sensor"""
    models = ['TempSense-Pro', 'ClimateGuard-X1', 'EnviroMonitor-2000', 'SensorMax-Elite']
    rooms = [f'Room {i}' for i in range(1, 21)]

    sensors = []
    for i in range(1, NUM_SENSORS + 1):
        sensor = {
            'sensor_id': f'sensor_{i:03d}',
            'model': random.choice(models),
            'location': rooms[i-1]
        }
        sensors.append(sensor)

    with open('sensors.csv', 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=['sensor_id', 'model', 'location'])
        writer.writeheader()
        writer.writerows(sensors)

    print(f"Generated sensors.csv with {len(sensors)} sensors")
    return sensors

# Generate timestamp range
def generate_timestamps(start, end, interval_minutes):
    """Generate list of timestamps from start to end with given interval"""
    timestamps = []
    current = start
    while current <= end:
        timestamps.append(current)
        current += timedelta(minutes=interval_minutes)
    return timestamps

# Generate time-series data with patterns
def generate_timeseries_data(sensors):
    """Generate data.csv with time-series sensor readings"""

    # Generate timestamp range
    timestamps = generate_timestamps(START_DATE, END_DATE, INTERVAL_MINUTES)

    with open('data.csv', 'w', newline='') as f:
        writer = csv.DictWriter(f, fieldnames=['timestamp', 'sensor_id', 'temperature', 'humidity'])
        writer.writeheader()

        row_count = 0
        for sensor in sensors:
            sensor_id = sensor['sensor_id']

            # Base temperature and humidity for this sensor (each sensor has slight variations)
            base_temp = random.uniform(18, 24)
            base_humidity = random.uniform(40, 60)

            for ts in timestamps:
                # Daily pattern: temperature peaks in afternoon, lowest at night
                hour = ts.hour + ts.minute / 60.0
                daily_temp_variation = 3 * math.sin((hour - 6) * math.pi / 12)  # Peak at 2 PM
                daily_humidity_variation = -5 * math.sin((hour - 6) * math.pi / 12)  # Inverse of temp

                # Weekly pattern: warmer on weekdays (office usage), cooler on weekends
                weekday = ts.weekday()
                weekly_temp_variation = -2 if weekday >= 5 else 1  # Cooler on weekends
                weekly_humidity_variation = 5 if weekday >= 5 else -2

                # Random noise
                temp_noise = random.gauss(0, 0.5)
                humidity_noise = random.gauss(0, 2)

                # Calculate final values
                temperature = base_temp + daily_temp_variation + weekly_temp_variation + temp_noise
                humidity = base_humidity + daily_humidity_variation + weekly_humidity_variation + humidity_noise

                # Clamp humidity to reasonable range
                humidity = max(20, min(80, humidity))

                writer.writerow({
                    'timestamp': ts.strftime('%Y-%m-%d %H:%M:%S'),
                    'sensor_id': sensor_id,
                    'temperature': round(temperature, 2),
                    'humidity': round(humidity, 2)
                })
                row_count += 1

    print(f"Generated data.csv with {row_count:,} rows ({len(sensors)} sensors × {len(timestamps):,} timestamps)")

# Main execution
if __name__ == "__main__":
    print("Starting data generation...")
    print(f"Date range: {START_DATE.strftime('%Y-%m-%d')} to {END_DATE.strftime('%Y-%m-%d')}")
    print(f"Interval: {INTERVAL_MINUTES} minute(s)")
    print()

    # Generate metadata
    sensors = generate_sensor_metadata()
    print()

    # Generate time-series data
    generate_timeseries_data(sensors)
    print()

    # Display sample data from generated files
    print("Sample from sensors.csv:")
    with open('sensors.csv', 'r') as f:
        lines = f.readlines()[:6]  # Header + 5 rows
        for line in lines:
            print(line.rstrip())

    print()
    print("Sample from data.csv:")
    with open('data.csv', 'r') as f:
        lines = f.readlines()[:11]  # Header + 10 rows
        for line in lines:
            print(line.rstrip())

    print()
    print("Data generation complete!")
