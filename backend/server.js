const express = require('express');
const mongoose = require('mongoose');
const cors = require('cors');
const admin = require('firebase-admin');

const app = express();
app.use(cors());
app.use(express.json({ limit: '10mb' }));

// Initialize Firebase Admin SDK
if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.applicationDefault(),
  });
}

mongoose.connect('mongodb+srv://panimalar:panimalar1234@panimalar.binwh1b.mongodb.net/?appName=panimalar')
  .then(() => console.log('✅ Connected to MongoDB Atlas'))
  .catch(err => console.error('❌ MongoDB connection error:', err));

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

const voiceMessageSchema = new mongoose.Schema({
  sender: String,
  receiver: String,
  audioBase64: { type: String, required: true },
  timestamp: { type: Date, default: Date.now },
  duration: Number
});

const VoiceMessage = mongoose.model('VoiceMessage', voiceMessageSchema);

const announcementSchema = new mongoose.Schema({
  title: String,
  message: String,
  attachmentBase64: String, // Can be image or pdf
  attachmentType: String, // 'image' or 'pdf'
  timestamp: { type: Date, default: Date.now },
  isActive: { type: Boolean, default: true }
});

const Announcement = mongoose.model('Announcement', announcementSchema);

// GET profile
app.get('/api/students/:rollNo', async (req, res) => {
  try {
    const student = await Student.findOne({ rollNo: req.params.rollNo });
    if (student) {
      res.json(student);
    } else {
      res.status(404).json({ message: 'Student not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// POST profile
app.post('/api/students/:rollNo', async (req, res) => {
  try {
    const { name, year, department, busNo, boardingStop, profilePicBase64 } = req.body;
    const student = await Student.findOneAndUpdate(
      { rollNo: req.params.rollNo },
      { name, year, department, busNo, boardingStop, profilePicBase64 },
      { new: true, upsert: true }
    );
    res.json(student);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// Root endpoint to verify server is running
app.get('/', (req, res) => {
  res.json({ status: '✅ Panimalar Backend is running successfully!' });
});

// POST voice message
app.post('/api/voice', async (req, res) => {
  try {
    const { sender, receiver, audioBase64, duration } = req.body;
    const voiceMessage = new VoiceMessage({ sender, receiver, audioBase64, duration });
    await voiceMessage.save();
    res.json({ id: voiceMessage._id });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// GET voice message
app.get('/api/voice/:id', async (req, res) => {
  try {
    const voiceMessage = await VoiceMessage.findById(req.params.id);
    if (voiceMessage) {
      res.json({ audioBase64: voiceMessage.audioBase64, duration: voiceMessage.duration });
    } else {
      res.status(404).json({ message: 'Voice message not found' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// POST Announcement
app.post('/api/announcements', async (req, res) => {
  try {
    const { title, message, attachmentBase64, attachmentType } = req.body;
    // Deactivate previous active announcements
    await Announcement.updateMany({ isActive: true }, { isActive: false });
    
    const announcement = new Announcement({ title, message, attachmentBase64, attachmentType, isActive: true });
    await announcement.save();
    res.json(announcement);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// GET Latest Announcement
app.get('/api/announcements/latest', async (req, res) => {
  try {
    const announcement = await Announcement.findOne({ isActive: true }).sort({ timestamp: -1 });
    if (announcement) {
      res.json(announcement);
    } else {
      res.status(404).json({ message: 'No active announcements' });
    }
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// DELETE Active Announcement
app.delete('/api/announcements/active', async (req, res) => {
  try {
    await Announcement.updateMany({ isActive: true }, { isActive: false });
    res.json({ message: 'Active announcements cleared' });
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

// POST: Send FCM push notification to admin when driver sends intercom message
app.post('/api/notify', async (req, res) => {
  try {
    const { fcmToken, busNo, messageType, messagePreview } = req.body;
    if (!fcmToken) {
      return res.status(400).json({ error: 'fcmToken is required' });
    }

    const isVoice = messageType === 'voice';
    const title = `📨 Route ${busNo} — Intercom Message`;
    const body = isVoice
      ? `Driver ${busNo} sent a voice message 🎤`
      : `Driver ${busNo}: ${messagePreview || 'New message'}`;

    const message = {
      token: fcmToken,
      notification: { title, body },
      android: {
        priority: 'high',
        notification: {
          channelId: 'intercom_channel',
          sound: 'default',
          priority: 'high',
          defaultSound: true,
        },
      },
      apns: {
        payload: {
          aps: { sound: 'default', badge: 1 },
        },
      },
    };

    await admin.messaging().send(message);
    res.json({ success: true });
  } catch (error) {
    console.error('FCM notify error:', error.message);
    res.status(500).json({ error: error.message });
  }
});

const PORT = 5001;
app.listen(PORT, () => {
  console.log(`🚀 Server running on port ${PORT}`);
});
