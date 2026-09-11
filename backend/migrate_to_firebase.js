const mongoose = require('mongoose');
const https = require('https');

async function putToFirebase(rollNo, payload) {
  return new Promise((resolve, reject) => {
    const data = JSON.stringify(payload);
    
    const options = {
      hostname: 'gen-lang-client-0636615491-default-rtdb.asia-southeast1.firebasedatabase.app',
      path: `/students/${rollNo}.json`,
      method: 'PUT',
      headers: {
        'Content-Type': 'application/json',
        'Content-Length': Buffer.byteLength(data)
      }
    };
    
    const req = https.request(options, (res) => {
      let responseBody = '';
      res.on('data', (chunk) => responseBody += chunk);
      res.on('end', () => {
        if (res.statusCode >= 200 && res.statusCode < 300) {
          resolve(responseBody);
        } else {
          reject(new Error(`Status Code: ${res.statusCode} ${responseBody}`));
        }
      });
    });
    
    req.on('error', (e) => reject(e));
    
    req.write(data);
    req.end();
  });
}

async function migrateData() {
  try {
    console.log('Connecting to MongoDB...');
    await mongoose.connect('mongodb+srv://panimalar:panimalar1234@panimalar.binwh1b.mongodb.net/?appName=panimalar');
    console.log('Connected to MongoDB');

    const studentSchema = new mongoose.Schema({
      rollNo: { type: String, required: true, unique: true },
      name: String,
      year: String,
      department: String,
      busNo: String,
      boardingStop: String,
      profilePicBase64: String
    });

    const Student = mongoose.model('Student', studentSchema);
    
    console.log('Fetching students from MongoDB...');
    const students = await Student.find({});
    console.log(`Found ${students.length} students in MongoDB.`);

    if (students.length === 0) {
      console.log('No students to migrate.');
      process.exit(0);
    }

    console.log('Uploading students to Firebase...');
    for (const student of students) {
      if (!student.rollNo) continue;
      
      const payload = {
        name: student.name || '',
        year: student.year || '',
        department: student.department || '',
        busNo: student.busNo || '',
        boardingStop: student.boardingStop || '',
        profilePicBase64: student.profilePicBase64 || ''
      };

      try {
        await putToFirebase(student.rollNo, payload);
        console.log(`Successfully migrated ${student.rollNo} to Firebase.`);
      } catch (err) {
        console.error(`Failed to migrate ${student.rollNo}:`, err.message);
      }
    }

    console.log('Deleting student profiles from MongoDB...');
    const deleteResult = await Student.deleteMany({});
    console.log(`Deleted ${deleteResult.deletedCount} students from MongoDB.`);
    
    console.log('Migration Complete.');
  } catch (error) {
    console.error('Migration error:', error);
  } finally {
    mongoose.connection.close();
  }
}

migrateData();
